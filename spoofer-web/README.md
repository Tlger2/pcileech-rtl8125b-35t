# Hardware Identity Lab

Browser workbench for RTL8125B / CaptainDMA hardware identity profiles:
disk serial / model / firmware, SMBIOS UUID / board / system serials, and
NIC MAC / IfGuid / IPv4. Edit, randomize, apply, and export JSON. Nothing
in this folder is a kernel driver or a published payload of one.

```
cd spoofer-web
npm install
npm run dev
```

Open http://127.0.0.1:5173
