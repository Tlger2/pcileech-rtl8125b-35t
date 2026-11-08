// Session establishment FSM for the FT601 control link.
//
// Four-message mutual-auth handshake rooted in PSK:
//   0xA0  CLIENT_HELLO     | client_nonce[128]
//   0xA1  SERVER_CHALLENGE | server_nonce[128] | mac_server[128]
//   0xA2  CLIENT_RESPONSE  | mac_client[128]
//   0xA3  SERVER_ACK       | session_id[16] | mac_ack[128]
//   0xAF  SESSION_RESET    | (no body) - tear down an established session
//
//   mac_server  = ChaCha20(PSK, client_nonce[:12], counter=0)[0..15]
//   mac_client  = ChaCha20(PSK, server_nonce[:12], counter=1)[0..15]
//   session_key = ChaCha20(PSK, client_nonce[:12] ^ server_nonce[:12],
//                               counter=2)[0..31]
//   session_id  = that same keystream[271:256] (16 bits)
//   mac_ack     = that same keystream[399:272] (16 bytes)
//
// Phase 3 replaces the stub assigns with two inline byte-level sub-FSMs:
//   RX sub-FSM — parses CLIENT_HELLO / CLIENT_RESPONSE / SESSION_RESET
//   TX sub-FSM — sends SERVER_CHALLENGE / SERVER_ACK byte-at-a-time
//
// All byte streams are MSB-first.

module secure_session_fsm #(
    parameter logic [255:0] PSK               = 256'h0,
    parameter int           HANDSHAKE_TIMEOUT = 125_000   // ~2 ms @ 62.5 MHz
) (
    input  logic         clk,
    input  logic         rst_n,

    // Inbound handshake bytes (from FT601 RX)
    input  logic         hs_rx_valid,
    input  logic [7:0]   hs_rx_byte,
    output logic         hs_rx_ready,

    // Outbound handshake bytes (to FT601 TX)
    output logic         hs_tx_valid,
    output logic [7:0]   hs_tx_byte,
    input  logic         hs_tx_ready,

    // TRNG for server nonce
    output logic         trng_pop,
    input  logic [63:0]  trng_nonce,
    input  logic         trng_valid,

    // ChaCha20 core (shared)
    output logic         cc_start,
    output logic [255:0] cc_key,
    output logic [95:0]  cc_nonce,
    output logic [31:0]  cc_block_counter,
    input  logic [511:0] cc_keystream,
    input  logic         cc_done,

    // Session output to data plane
    output logic [255:0] session_key,
    output logic [15:0]  session_id,
    output logic         session_established,
    output logic         session_reset
);

    // ------------------------------------------------------------------ //
    //  Main handshake FSM states                                          //
    // ------------------------------------------------------------------ //
    typedef enum logic [3:0] {
        H_IDLE,
        H_WAIT_HELLO,
        H_MAKE_SNONCE_LO,
        H_MAKE_SNONCE_HI,
        H_COMPUTE_MAC_S,
        H_SEND_CHALLENGE,
        H_WAIT_RESPONSE,
        H_COMPUTE_MAC_C,
        H_DERIVE_KEY,
        H_SEND_ACK,
        H_ESTABLISHED,
        H_FAULT
    } hs_state_t;

    hs_state_t    h_state;
    logic [127:0] client_nonce_q;
    logic [127:0] server_nonce_q;
    logic [127:0] mac_server_q;
    logic [127:0] mac_ack_q;
    logic [127:0] mac_client_expected;
    logic [127:0] mac_client_received;
    logic [31:0]  timeout_cnt;

    // ------------------------------------------------------------------ //
    //  RX byte sub-FSM                                                    //
    //  Parses CLIENT_HELLO (0xA0 + 16B nonce)                            //
    //          CLIENT_RESPONSE (0xA2 + 16B mac)                          //
    //          SESSION_RESET (0xAF)                                       //
    // ------------------------------------------------------------------ //
    typedef enum logic [1:0] {
        RX_IDLE,
        RX_CNONCE,
        RX_CMAC
    } rx_st_t;

    rx_st_t      rx_state;
    logic [4:0]  rx_cnt;         // byte counter 0..15

    // Single-cycle completion pulses (set by RX sub-FSM, cleared top-of-block)
    logic hello_done;
    logic response_done;

    // ------------------------------------------------------------------ //
    //  TX byte sub-FSM                                                    //
    //  Sends SERVER_CHALLENGE (0xA1 + 16B nonce + 16B mac  = 33 B)       //
    //         SERVER_ACK      (0xA3 + 2B  id    + 16B mac  = 19 B)       //
    // ------------------------------------------------------------------ //
    typedef enum logic [1:0] {
        TX_IDLE,
        TX_CHALLENGE,
        TX_ACK
    } tx_st_t;

    tx_st_t      tx_state;
    logic [5:0]  tx_cnt;         // byte counter; max = 32 (challenge)

    // Single-cycle completion pulses (set by TX sub-FSM, cleared top-of-block)
    logic challenge_tx_done;
    logic ack_tx_done;

    // ------------------------------------------------------------------ //
    //  Constant-time 128-bit compare                                      //
    // ------------------------------------------------------------------ //
    function automatic logic ct_eq_128(input logic [127:0] a, b);
        logic [127:0] diff;
        diff = a ^ b;
        ct_eq_128 = ~(|diff);
    endfunction

    // ------------------------------------------------------------------ //
    //  RX flow control — always ready (we never back-pressure the host)   //
    // ------------------------------------------------------------------ //
    assign hs_rx_ready = 1'b1;

    // ------------------------------------------------------------------ //
    //  TX data byte mux (combinational)                                   //
    //  hs_tx_valid pulses while TX sub-FSM is active.                     //
    //  Downstream latches each byte on (hs_tx_valid & hs_tx_ready).       //
    // ------------------------------------------------------------------ //
    always_comb begin
        hs_tx_valid = (tx_state != TX_IDLE);
        hs_tx_byte  = 8'h00;

        if (tx_state == TX_CHALLENGE) begin
            case (tx_cnt)
                // opcode
                6'd0:    hs_tx_byte = 8'hA1;
                // server_nonce[127:0] MSB-first (bytes 1..16)
                6'd1:    hs_tx_byte = server_nonce_q[127:120];
                6'd2:    hs_tx_byte = server_nonce_q[119:112];
                6'd3:    hs_tx_byte = server_nonce_q[111:104];
                6'd4:    hs_tx_byte = server_nonce_q[103: 96];
                6'd5:    hs_tx_byte = server_nonce_q[ 95: 88];
                6'd6:    hs_tx_byte = server_nonce_q[ 87: 80];
                6'd7:    hs_tx_byte = server_nonce_q[ 79: 72];
                6'd8:    hs_tx_byte = server_nonce_q[ 71: 64];
                6'd9:    hs_tx_byte = server_nonce_q[ 63: 56];
                6'd10:   hs_tx_byte = server_nonce_q[ 55: 48];
                6'd11:   hs_tx_byte = server_nonce_q[ 47: 40];
                6'd12:   hs_tx_byte = server_nonce_q[ 39: 32];
                6'd13:   hs_tx_byte = server_nonce_q[ 31: 24];
                6'd14:   hs_tx_byte = server_nonce_q[ 23: 16];
                6'd15:   hs_tx_byte = server_nonce_q[ 15:  8];
                6'd16:   hs_tx_byte = server_nonce_q[  7:  0];
                // mac_server[127:0] MSB-first (bytes 17..32)
                6'd17:   hs_tx_byte = mac_server_q[127:120];
                6'd18:   hs_tx_byte = mac_server_q[119:112];
                6'd19:   hs_tx_byte = mac_server_q[111:104];
                6'd20:   hs_tx_byte = mac_server_q[103: 96];
                6'd21:   hs_tx_byte = mac_server_q[ 95: 88];
                6'd22:   hs_tx_byte = mac_server_q[ 87: 80];
                6'd23:   hs_tx_byte = mac_server_q[ 79: 72];
                6'd24:   hs_tx_byte = mac_server_q[ 71: 64];
                6'd25:   hs_tx_byte = mac_server_q[ 63: 56];
                6'd26:   hs_tx_byte = mac_server_q[ 55: 48];
                6'd27:   hs_tx_byte = mac_server_q[ 47: 40];
                6'd28:   hs_tx_byte = mac_server_q[ 39: 32];
                6'd29:   hs_tx_byte = mac_server_q[ 31: 24];
                6'd30:   hs_tx_byte = mac_server_q[ 23: 16];
                6'd31:   hs_tx_byte = mac_server_q[ 15:  8];
                6'd32:   hs_tx_byte = mac_server_q[  7:  0];
                default: hs_tx_byte = 8'h00;
            endcase

        end else if (tx_state == TX_ACK) begin
            case (tx_cnt)
                // opcode
                6'd0:    hs_tx_byte = 8'hA3;
                // session_id[15:0] MSB-first (bytes 1..2)
                6'd1:    hs_tx_byte = session_id[15:8];
                6'd2:    hs_tx_byte = session_id[ 7:0];
                // mac_ack[127:0] MSB-first (bytes 3..18)
                6'd3:    hs_tx_byte = mac_ack_q[127:120];
                6'd4:    hs_tx_byte = mac_ack_q[119:112];
                6'd5:    hs_tx_byte = mac_ack_q[111:104];
                6'd6:    hs_tx_byte = mac_ack_q[103: 96];
                6'd7:    hs_tx_byte = mac_ack_q[ 95: 88];
                6'd8:    hs_tx_byte = mac_ack_q[ 87: 80];
                6'd9:    hs_tx_byte = mac_ack_q[ 79: 72];
                6'd10:   hs_tx_byte = mac_ack_q[ 71: 64];
                6'd11:   hs_tx_byte = mac_ack_q[ 63: 56];
                6'd12:   hs_tx_byte = mac_ack_q[ 55: 48];
                6'd13:   hs_tx_byte = mac_ack_q[ 47: 40];
                6'd14:   hs_tx_byte = mac_ack_q[ 39: 32];
                6'd15:   hs_tx_byte = mac_ack_q[ 31: 24];
                6'd16:   hs_tx_byte = mac_ack_q[ 23: 16];
                6'd17:   hs_tx_byte = mac_ack_q[ 15:  8];
                6'd18:   hs_tx_byte = mac_ack_q[  7:  0];
                default: hs_tx_byte = 8'h00;
            endcase
        end
    end

    // ------------------------------------------------------------------ //
    //  Clocked logic — all three FSMs share one always_ff block           //
    //  to avoid multi-driver conflicts on shared state (h_state, etc.).   //
    //  NB: in SystemVerilog, non-blocking RHS reads the PRE-CLOCK value,  //
    //  so sub-FSM updates to pulse signals are visible to the main FSM    //
    //  in the FOLLOWING cycle, giving clean one-cycle pulses.             //
    // ------------------------------------------------------------------ //
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // --- main FSM ---
            h_state             <= H_IDLE;
            session_established <= 1'b0;
            session_reset       <= 1'b0;
            session_key         <= 256'h0;
            session_id          <= 16'h0;
            timeout_cnt         <= 32'h0;
            trng_pop            <= 1'b0;
            cc_start            <= 1'b0;
            cc_key              <= 256'h0;
            cc_nonce            <= 96'h0;
            cc_block_counter    <= 32'h0;
            client_nonce_q      <= 128'h0;
            server_nonce_q      <= 128'h0;
            mac_server_q        <= 128'h0;
            mac_ack_q           <= 128'h0;
            mac_client_expected <= 128'h0;
            mac_client_received <= 128'h0;
            // --- RX sub-FSM ---
            rx_state      <= RX_IDLE;
            rx_cnt        <= 5'h0;
            hello_done    <= 1'b0;
            response_done <= 1'b0;
            // --- TX sub-FSM ---
            tx_state          <= TX_IDLE;
            tx_cnt            <= 6'h0;
            challenge_tx_done <= 1'b0;
            ack_tx_done       <= 1'b0;

        end else begin
            // Clear single-cycle pulses at top; sub-FSMs may re-set them below
            trng_pop          <= 1'b0;
            cc_start          <= 1'b0;
            session_reset     <= 1'b0;
            hello_done        <= 1'b0;
            response_done     <= 1'b0;
            challenge_tx_done <= 1'b0;
            ack_tx_done       <= 1'b0;

            // ===========================================================
            // RX byte sub-FSM
            // ===========================================================
            if (hs_rx_valid) begin
                case (rx_state)
                    RX_IDLE: begin
                        case (hs_rx_byte)
                            8'hA0: begin
                                rx_state <= RX_CNONCE;
                                rx_cnt   <= 5'h0;
                            end
                            8'hA2: begin
                                rx_state <= RX_CMAC;
                                rx_cnt   <= 5'h0;
                            end
                            8'hAF: begin
                                // Explicit session reset from client
                                session_established <= 1'b0;
                                session_reset       <= 1'b1;
                                h_state             <= H_IDLE;
                                rx_state            <= RX_IDLE;
                                tx_state            <= TX_IDLE;
                            end
                            default: ; // unknown opcode, stay in RX_IDLE
                        endcase
                    end

                    RX_CNONCE: begin
                        // Accumulate 16 bytes MSB-first into client_nonce_q
                        client_nonce_q <= {client_nonce_q[119:0], hs_rx_byte};
                        if (rx_cnt == 5'd15) begin
                            rx_state   <= RX_IDLE;
                            rx_cnt     <= 5'h0;
                            hello_done <= 1'b1;
                        end else begin
                            rx_cnt <= rx_cnt + 5'h1;
                        end
                    end

                    RX_CMAC: begin
                        // Accumulate 16 bytes MSB-first into mac_client_received
                        mac_client_received <= {mac_client_received[119:0], hs_rx_byte};
                        if (rx_cnt == 5'd15) begin
                            rx_state      <= RX_IDLE;
                            rx_cnt        <= 5'h0;
                            response_done <= 1'b1;
                        end else begin
                            rx_cnt <= rx_cnt + 5'h1;
                        end
                    end
                endcase
            end

            // ===========================================================
            // TX byte sub-FSM
            // Advances tx_cnt on each accepted byte (hs_tx_ready asserted).
            // hs_tx_valid / hs_tx_byte are purely combinational (above).
            // ===========================================================
            case (tx_state)
                TX_IDLE: begin
                    if (h_state == H_SEND_CHALLENGE) begin
                        tx_state <= TX_CHALLENGE;
                        tx_cnt   <= 6'h0;
                    end else if (h_state == H_SEND_ACK) begin
                        tx_state <= TX_ACK;
                        tx_cnt   <= 6'h0;
                    end
                end

                TX_CHALLENGE: begin
                    if (hs_tx_ready) begin
                        if (tx_cnt == 6'd32) begin
                            tx_state          <= TX_IDLE;
                            tx_cnt            <= 6'h0;
                            challenge_tx_done <= 1'b1;
                        end else begin
                            tx_cnt <= tx_cnt + 6'h1;
                        end
                    end
                end

                TX_ACK: begin
                    if (hs_tx_ready) begin
                        if (tx_cnt == 6'd18) begin
                            tx_state    <= TX_IDLE;
                            tx_cnt      <= 6'h0;
                            ack_tx_done <= 1'b1;
                        end else begin
                            tx_cnt <= tx_cnt + 6'h1;
                        end
                    end
                end
            endcase

            // ===========================================================
            // Handshake-wide timeout
            // ===========================================================
            if (h_state != H_IDLE && h_state != H_ESTABLISHED
                                   && h_state != H_FAULT) begin
                timeout_cnt <= timeout_cnt + 1'b1;
                if (timeout_cnt == HANDSHAKE_TIMEOUT[31:0])
                    h_state <= H_FAULT;
            end else begin
                timeout_cnt <= 32'h0;
            end

            // ===========================================================
            // Main handshake FSM
            // ===========================================================
            unique case (h_state)
                H_IDLE:
                    h_state <= H_WAIT_HELLO;

                H_WAIT_HELLO:
                    if (hello_done) h_state <= H_MAKE_SNONCE_LO;

                H_MAKE_SNONCE_LO: begin
                    trng_pop <= 1'b1;
                    if (trng_valid) begin
                        server_nonce_q[63:0] <= trng_nonce;
                        h_state              <= H_MAKE_SNONCE_HI;
                    end
                end

                H_MAKE_SNONCE_HI: begin
                    trng_pop <= 1'b1;
                    if (trng_valid) begin
                        server_nonce_q[127:64] <= trng_nonce;
                        h_state                <= H_COMPUTE_MAC_S;
                    end
                end

                H_COMPUTE_MAC_S: begin
                    cc_start         <= 1'b1;
                    cc_key           <= PSK;
                    cc_nonce         <= client_nonce_q[95:0];
                    cc_block_counter <= 32'd0;
                    if (cc_done) begin
                        mac_server_q <= cc_keystream[127:0];
                        h_state      <= H_SEND_CHALLENGE;
                    end
                end

                H_SEND_CHALLENGE:
                    if (challenge_tx_done) h_state <= H_WAIT_RESPONSE;

                H_WAIT_RESPONSE:
                    if (response_done) h_state <= H_COMPUTE_MAC_C;

                H_COMPUTE_MAC_C: begin
                    cc_start         <= 1'b1;
                    cc_key           <= PSK;
                    cc_nonce         <= server_nonce_q[95:0];
                    cc_block_counter <= 32'd1;
                    if (cc_done) begin
                        mac_client_expected <= cc_keystream[127:0];
                        h_state             <= H_DERIVE_KEY;
                    end
                end

                H_DERIVE_KEY: begin
                    if (!ct_eq_128(mac_client_received, mac_client_expected)) begin
                        h_state <= H_FAULT;
                    end else begin
                        cc_start         <= 1'b1;
                        cc_key           <= PSK;
                        cc_nonce         <= client_nonce_q[95:0]
                                           ^ server_nonce_q[95:0];
                        cc_block_counter <= 32'd2;
                        if (cc_done) begin
                            session_key <= cc_keystream[255:0];
                            session_id  <= cc_keystream[271:256];
                            mac_ack_q   <= cc_keystream[399:272]; // bytes 32..47 of block
                            h_state     <= H_SEND_ACK;
                        end
                    end
                end

                H_SEND_ACK:
                    if (ack_tx_done) begin
                        session_established <= 1'b1;
                        h_state             <= H_ESTABLISHED;
                    end

                H_ESTABLISHED: begin
                    // Idle until SESSION_RESET (handled by RX sub-FSM above)
                    // or external decrypt failure signal from data plane.
                end

                H_FAULT: begin
                    session_established <= 1'b0;
                    session_reset       <= 1'b1;
                    h_state             <= H_IDLE;
                    rx_state            <= RX_IDLE;
                    tx_state            <= TX_IDLE;
                end
            endcase
        end
    end

endmodule
