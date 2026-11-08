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
//   session_id  = that same keystream[256..271]
//
// The ChaCha20 core is shared with the data plane (secure_frame_enc/dec).
// The byte-level RX/TX framing shift registers are stubbed here with
// TODO markers; wire them to your FT601 parser/packager during
// integration.

module secure_session_fsm #(
    parameter logic [255:0] PSK               = 256'h0,
    parameter int           HANDSHAKE_TIMEOUT = 125_000   // ~2 ms
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

    hs_state_t   h_state;
    logic [127:0] client_nonce_q;
    logic [127:0] server_nonce_q;
    logic [127:0] mac_server_q;
    logic [127:0] mac_client_expected;
    logic [127:0] mac_client_received;  // populated by RX framing TODO
    logic [31:0]  timeout_cnt;

    // Internal flags filled in by the (stubbed) byte-level RX/TX loops.
    // TODO: wire these to real shift registers the way ft601_cmd_parser does.
    logic hello_done;        // CLIENT_HELLO fully received into client_nonce_q
    logic response_done;     // CLIENT_RESPONSE fully received into mac_client_received
    logic challenge_tx_done; // SERVER_CHALLENGE fully transmitted
    logic ack_tx_done;       // SERVER_ACK fully transmitted

    // Stubs (always 0) — remove once byte framing is wired.
    assign hello_done        = 1'b0;
    assign response_done     = 1'b0;
    assign challenge_tx_done = 1'b0;
    assign ack_tx_done       = 1'b0;

    // RX/TX byte interface stubs
    assign hs_rx_ready = 1'b1;
    assign hs_tx_valid = 1'b0;
    assign hs_tx_byte  = 8'h00;

    // Constant-time 128-bit compare
    function automatic logic ct_eq_128(input logic [127:0] a, b);
        logic [127:0] diff;
        diff = a ^ b;
        ct_eq_128 = ~(|diff);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
            mac_client_expected <= 128'h0;
            mac_client_received <= 128'h0;
        end else begin
            trng_pop      <= 1'b0;
            cc_start      <= 1'b0;
            session_reset <= 1'b0;

            // Handshake-wide timeout
            if (h_state != H_IDLE && h_state != H_ESTABLISHED
                                    && h_state != H_FAULT) begin
                timeout_cnt <= timeout_cnt + 1'b1;
                if (timeout_cnt == HANDSHAKE_TIMEOUT[31:0]) begin
                    h_state       <= H_FAULT;
                end
            end else begin
                timeout_cnt <= 32'h0;
            end

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
                    if (!ct_eq_128(mac_client_received, mac_client_expected))
                        h_state <= H_FAULT;
                    else begin
                        cc_start         <= 1'b1;
                        cc_key           <= PSK;
                        cc_nonce         <= client_nonce_q[95:0]
                                           ^ server_nonce_q[95:0];
                        cc_block_counter <= 32'd2;
                        if (cc_done) begin
                            session_key <= cc_keystream[255:0];
                            session_id  <= cc_keystream[271:256];
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
                    // Idle until explicit reset or decrypt failure signals
                    // from the data plane.
                end

                H_FAULT: begin
                    session_established <= 1'b0;
                    session_reset       <= 1'b1;
                    h_state             <= H_IDLE;
                end
            endcase
        end
    end
endmodule
