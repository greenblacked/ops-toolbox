- The macOS suite no longer fails according to the filesystem underneath its
  container. `step_downloads` totals with `du -sk`, which measures blocks on
  disk, and `du -sk` of a directory charges for the directory itself — one 4K
  block on ext4 and APFS, nothing on the overlayfs the tester usually runs on.
  The downloads fixture put a 64K file inside a directory next to a 2048K file,
  where that 4K decided the last digit: the total reads 2.06M or 2.07M
  depending on the host's Docker storage driver, and the suite asserted 2.07M.
  The fixture now lands on exactly 3.00M, far enough from the rounding boundary
  that the directory's block cannot move it. `stay_fresh.sh` was right all
  along — blocks on disk is the honest answer to "how much would this free".
