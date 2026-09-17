#!/usr/bin/env bash
# Fixture-only checks: no kernel build, Docker, network, or elevated privileges.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck disable=SC1090
source "${ROOT}/lib/kernel.sh"

fatal() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
warn() { :; }

for function in kernel_validate_config kernel_validate_btf kernel_validate_build; do
    declare -F "${function}" >/dev/null || fatal "missing function: ${function}"
done

expect_failure() {
    if ( "$@" ); then
        fatal "unexpected success: $*"
    fi
}

cat > "${TMP}/requirements" <<'EOF'
# DAE prerequisites and an unrelated comment.
CONFIG_BPF=y
CONFIG_NET_CLS_BPF=m
# CONFIG_DEBUG_INFO_REDUCED is not set
ignored text
EOF

cat > "${TMP}/config" <<'EOF'
CONFIG_BPF=y
CONFIG_NET_CLS_BPF=m
# CONFIG_DEBUG_INFO_REDUCED is not set
CONFIG_UNRELATED=y
EOF
kernel_validate_config "${TMP}/config" "${TMP}/requirements"

# A built-in implementation satisfies a module requirement; absent disabled
# options are valid in a generated .config too.
printf 'CONFIG_BPF=y\nCONFIG_NET_CLS_BPF=y\n' > "${TMP}/config"
kernel_validate_config "${TMP}/config" "${TMP}/requirements"

# Built-in requirements must not silently accept modules, disabled, or absent.
for value in m n absent; do
    printf 'CONFIG_NET_CLS_BPF=m\n' > "${TMP}/config"
    if [[ "${value}" != absent ]]; then
        printf 'CONFIG_BPF=%s\n' "${value}" >> "${TMP}/config"
    fi
    expect_failure kernel_validate_config "${TMP}/config" "${TMP}/requirements"
done

printf 'CONFIG_BPF=y\n# CONFIG_NET_CLS_BPF is not set\n' > "${TMP}/config"
expect_failure kernel_validate_config "${TMP}/config" "${TMP}/requirements"
printf 'CONFIG_BPF=y\n' > "${TMP}/config"
expect_failure kernel_validate_config "${TMP}/config" "${TMP}/requirements"

for value in y m; do
    printf 'CONFIG_BPF=y\nCONFIG_NET_CLS_BPF=m\nCONFIG_DEBUG_INFO_REDUCED=%s\n' \
        "${value}" > "${TMP}/config"
    expect_failure kernel_validate_config "${TMP}/config" "${TMP}/requirements"
done

expect_failure kernel_validate_config "${TMP}/missing" "${TMP}/requirements"
expect_failure kernel_validate_config "${TMP}/config" "${TMP}/missing"
: > "${TMP}/empty"
expect_failure kernel_validate_config "${TMP}/config" "${TMP}/empty"
printf '# No requirements\nunrecognized text\n' > "${TMP}/comments"
expect_failure kernel_validate_config "${TMP}/config" "${TMP}/comments"

# Model readelf's wide section table, including its variable-width index.
# The fixture vmlinux contains the section table the mock should return.
mkdir "${TMP}/bin"
cat > "${TMP}/bin/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 2 && "$1" == -SW ]] || exit 2
[[ -f "$2" ]] || exit 1
if grep -qx corrupt "$2"; then
    # Even plausible stdout must not hide a readelf failure.
    printf '  [12] .BTF PROGBITS 0000000000000000 000040 001000 00 A 0 0 4\n'
    exit 1
fi
cat "$2"
EOF
chmod +x "${TMP}/bin/readelf"
export PATH="${TMP}/bin:${PATH}"

for index in ' 9' '12'; do
    printf '  [%s] .BTF PROGBITS ffff800080000000 000040 001000 00 A 0 0 4\n' \
        "${index}" > "${TMP}/vmlinux"
    kernel_validate_btf "${TMP}/vmlinux"
done

for section in \
    '.text PROGBITS 0000000000000000 000040 001000 00 AX 0 0 4' \
    '.BTF.ext PROGBITS 0000000000000000 000040 001000 00 A 0 0 4' \
    '.BTF PROGBITS 0000000000000000 000040 000000 00 A 0 0 4' \
    '.BTF NOBITS 0000000000000000 000040 001000 00 A 0 0 4'; do
    printf '  [12] %s\n' "${section}" > "${TMP}/vmlinux"
    expect_failure kernel_validate_btf "${TMP}/vmlinux"
done
printf 'corrupt\n' > "${TMP}/vmlinux"
expect_failure kernel_validate_btf "${TMP}/vmlinux"
expect_failure kernel_validate_btf "${TMP}/missing"
expect_failure kernel_validate_btf "${TMP}/empty"

# A mock deb emits a real tar stream, exercising extraction and byte matching.
cat > "${TMP}/bin/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 2 && "$1" == --fsys-tarfile ]] || exit 2
cat "$2"
EOF
chmod +x "${TMP}/bin/dpkg-deb"
mkdir -p "${TMP}/src/arch/arm64/boot" "${TMP}/package/boot"
printf 'CONFIG_BPF=y\nCONFIG_NET_CLS_BPF=m\n' > "${TMP}/src/.config"
printf '  [12] .BTF PROGBITS 0000000000000000 000040 001000 00 A 0 0 4\n' \
    > "${TMP}/src/vmlinux"
printf 'kernel image\n' > "${TMP}/src/arch/arm64/boot/Image"

reset_package() {
    cp "${TMP}/src/.config" "${TMP}/package/boot/config-test-vyos"
    cp "${TMP}/src/arch/arm64/boot/Image" "${TMP}/package/boot/vmlinuz-test-vyos"
}
pack_fixture() {
    tar -cf "${TMP}/kernel.deb" -C "${TMP}/package" ./boot
}
check_package() {
    kernel_validate_build "${TMP}/src" "${TMP}/kernel.deb" test "${TMP}/requirements"
}

reset_package
pack_fixture
check_package

# ARM64 packages normally contain Image.gz rather than an uncompressed Image.
gzip -c "${TMP}/src/arch/arm64/boot/Image" > "${TMP}/package/boot/vmlinuz-test-vyos"
pack_fixture
check_package
printf 'different image\n' | gzip > "${TMP}/package/boot/vmlinuz-test-vyos"
pack_fixture
expect_failure check_package
reset_package

# Tree BTF cannot compensate for missing features in the shipped config.
printf 'CONFIG_NET_CLS_BPF=m\n' > "${TMP}/package/boot/config-test-vyos"
pack_fixture
expect_failure check_package

# Both configs can satisfy the contract yet describe different kernels.
reset_package
printf 'CONFIG_UNRELATED=y\n' >> "${TMP}/package/boot/config-test-vyos"
pack_fixture
expect_failure check_package

reset_package
printf 'different kernel image\n' > "${TMP}/package/boot/vmlinuz-test-vyos"
pack_fixture
expect_failure check_package

reset_package
rm "${TMP}/package/boot/vmlinuz-test-vyos"
pack_fixture
expect_failure check_package

printf 'not a tar archive\n' > "${TMP}/kernel.deb"
expect_failure check_package

reset_package
pack_fixture
check_package

printf 'kernel feature tests passed\n'
