Candidate `pd-mapper` firmware metadata files for `w737`.

Why these files:

- Target log shows `pd-mapper.service` fails with `no pd maps available`.
- `pd-mapper` scans `/sys/class/remoteproc` and firmware directories for `.jsn` service-registry maps.
- `/usr/lib/firmware/qcom/sdm850/samsung/w737/` currently has only `.mbn/.elf` files and no `.jsn`.
- Other Qualcomm platforms ship files like `adspr.jsn`, `adspua.jsn`, `cdspr.jsn`, `modemuw.jsn`.

Copy these into the target rootfs:

- `usr/lib/firmware/qcom/sdm850/samsung/w737/adspr.jsn`
- `usr/lib/firmware/qcom/sdm850/samsung/w737/adspua.jsn`
- `usr/lib/firmware/qcom/sdm850/samsung/w737/cdspr.jsn`
- `usr/lib/firmware/qcom/sdm850/samsung/w737/modemuw.jsn`

Then reboot or at least run:

```sh
systemctl restart qrtr-ns.service
systemctl reset-failed pd-mapper.service
systemctl restart pd-mapper.service
systemctl restart tqftpserv.service
systemctl restart iwd.service
```

Success criteria:

- `systemctl status pd-mapper` becomes `active (running)` instead of `no pd maps available`
- the next Wi-Fi diag log shows new `ath10k` / QMI progress after `ath10k_snoc 18800000.wifi: Adding to iommu group 8`

These files are a best-fit hypothesis based on the installed Qualcomm firmware layout for nearby SoCs, not a confirmed vendor dump for Samsung `w737`.
