# Mesa patches

Upstream project: Mesa, https://www.mesa3d.org

Apply to: **26.2.5** (the version the `mesa` package on the `pmos` branch builds). Upstream license: MIT AND SGI-B-2.0 AND BSL-1.0 (as the Alpine/postmarketOS package declares).

Freedreno fixes for the Adreno 508/509/512 class (A5xx) found while bringing up the RS6's Adreno 512: CCU_CNTL values, 2D copy and texture re-emit, the highest bank bit, ECO registers and 2D blits programmed the way Qualcomm's driver programs the A508/A509/A512 (lock-screen tiling with FD_MESA_DEBUG=noblit, UI elements vanishing for a frame with the 2D engine), and A8 read as A8 in 2D SCALE blits (Qt text glyphs). 0101-0103 are by Fabricio Akio and are carried here as received; 0104-0106 are by Noa Himesaka. Alpine's own patches in the Mesa package (23575.patch, llvm23.patch, riscv64-tls.patch) are not duplicated here.

Patches (in order):

- `0101-freedreno-a5xx-Use-the-blob-s-RB_CCU_CNTL-values-on-A508.patch`
- `0102-freedreno-a5xx-Don-t-2D-copy-between-linear-surfaces-on-A508.patch`
- `0103-freedreno-a5xx-Re-emit-fragment-textures-when-the-fragment-program-changes.patch`
- `0104-freedreno-a5xx-Use-the-blob-s-RB_CCU_CNTL-values-on-A509-and-A512.patch`
- `0105-freedreno-a5xx-Program-the-A508-A509-A512-the-way-Qualcomm-s-driver-does.patch`
- `0106-freedreno-a5xx-Read-A8-as-A8-in-SCALE-blits.patch`

Authors: Fabricio Akio <fabricioakio@gmail.com>; Noa Himesaka <himesaka@noa.codes>.

The patches are `git format-patch` output against the upstream release; apply with `patch -p1` or `git am`.
They are licensed like the project they patch.
