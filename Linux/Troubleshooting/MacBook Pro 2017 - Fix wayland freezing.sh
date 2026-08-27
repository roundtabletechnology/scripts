# Fixes wayland freezing
# Disable i915 DC (Display Controller) and FBC (Frame Buffer Compression) to fix freezing issues on MacBook Pro 2017 with Wayland
sudo grubby --update-kernel=ALL --args="i915.enable_dc=0 i915.enable_fbc=0"
