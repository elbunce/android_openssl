#!/bin/bash

## Prerequisites
## On both Linux, macOS: 'patchelf' command is needed for OpenSSL 3+
## On macOS:
##   - bash shell version 4+ is required
##   - wget command

BUILD_DIR=$(pwd)

if [ "$(uname)" == "Darwin" ]; then
		ANDROIDNDKROOT=$HOME/Library/Android/sdk/ndk
		CORES=$(sysctl -n hw.ncpu)
else
		ANDROIDNDKROOT=$HOME/android/ndk
		CORES=$(nrpoc)
fi

# Comment out the line for any configuration you don't want to build
declare -a params=(
    ''
    'no-asm'
)
declare -A ssl_versions_output_dir=(
    ["ssl_1.1"]="1.1*"
    ["ssl_3"]="3*"
)
declare -A ssl_versions_ndk=(
    ["1.1.1w"]="$ANDROIDNDKROOT/21.4.7075529"
    ["3.4.1"]="$ANDROIDNDKROOT/25.2.9519653"
)
declare -A architectures=(
    ["x86_64"]="x86_64"
    ["x86"]="x86"
    ["arm64"]="arm64-v8a"
    ["arm"]="armeabi-v7a"
)

download_ssl_version() {
    ssl_version=$1
    echo "Downloading OpenSSL $ssl_version"
    if [ ! -f "$ssl_version.tar.gz" ]; then
	case $ssl_version in
	    1.1*)
		wget -q --show-progress "https://www.openssl.org/source/openssl-$ssl_version.tar.gz"
		;;
	    3*)
		wget --show-progress "https://github.com/openssl/openssl/releases/download/openssl-$ssl_version/openssl-$ssl_version.tar.gz"
		;;
	esac
    fi
}

extract_package() {
    qt_arch=$1
    version=$2
    ssl_version=$3

    echo "Extracting OpenSSL $ssl_version under $(pwd)"
    rm -fr "$qt_arch" "$version/$qt_arch"
    mkdir -p "$version/$qt_arch" || exit 1
    rm -fr "openssl-$ssl_version"
    tar xf "openssl-$ssl_version.tar.gz" || exit 1
}

configure_ssl() {
    ndk=$1
    param=$2
    ssl_version=$3
    version_out_dir=$4
    arch=$5
    log_file=$6

    export ANDROID_NDK_HOME="${ndk}"
    export ANDROID_NDK_ROOT="${ndk}"

    declare hosts=("linux-x86_64" "linux-x86" "darwin-x86_64" "darwin-x86")
    for host in "${hosts[@]}"; do
        if [ -d "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$host/bin" ]; then
            ANDROID_TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$host/bin"
            export PATH="$ANDROID_TOOLCHAIN:$PATH"
            break
        fi
    done

    case $version_out_dir in
    ssl_1.1)
        ANDROID_API=21
	arch_prefix=
        ;;
    ssl_3)
        ANDROID_API=23
	arch_prefix=qt
	pwd
echo	cp -v ${BUILD_DIR}/20-qtandroid.conf Configurations
	cp -v ${BUILD_DIR}/20-qtandroid.conf Configurations
        ;;
    esac

    config_params=( "${param}" "shared" "${arch_prefix}android-${arch}"
                    "-U__ANDROID_API__" "-D__ANDROID_API__=${ANDROID_API}" )
    echo "Configuring OpenSSL $ssl_version with parameters: ${config_params[@]}"

    ./Configure "${config_params[@]}" 2>&1 1>${log_file} | tee -a ${log_file} || exit 1
    make depend
}

build_ssl_1_1() {
    # Qt up to 6.4 is using OpenSSL 1.1.x but the library is suffixed with _1_1.so
    version_out_dir=$1
    qt_arch=$2
    log_file=$3

    echo "Building..."
    make -j$CORES SHLIB_VERSION_NUMBER= SHLIB_EXT=_1_1.so build_libs 2>&1 1>>${log_file} | tee -a ${log_file} || exit 1
    llvm-strip --strip-all libcrypto_1_1.so
    llvm-strip --strip-all libssl_1_1.so
    cp -v libcrypto_1_1.so libssl_1_1.so "../$version_out_dir/$qt_arch" || exit 1
    cp -v libcrypto.a libssl.a "../$version_out_dir/$qt_arch" || exit 1
}

build_ssl_3() {
    # Qt 6.5.0+ is using OpenSSL 3.1.x but the library is suffixed with _3.so
    version_out_dir=$1
    qt_arch=$2
    log_file=$3

    echo "Building..."
    make -j$CORES build_libs 2>&1 1>>${log_file} | tee -a ${log_file} || exit 1
    llvm-strip --strip-all libcrypto_3.so
    llvm-strip --strip-all libssl_3.so

    out_path="../$version_out_dir/$qt_arch"
    cp -v libcrypto.a libssl.a "${out_path}" || exit 1
    cp -v libcrypto_3.so "${out_path}/libcrypto_3.so" || exit 1
    cp -v libssl_3.so "${out_path}/libssl_3.so" || exit 1
}

for param in "${params[@]}"; do
    if [ "${param}" ]; then
        rm -fr "${param}"
        mkdir "${param}"
        pushd "${param}"
    fi
    for ssl_version in "${!ssl_versions_ndk[@]}"; do
        download_ssl_version $ssl_version

        for version_out_dir in "${!ssl_versions_output_dir[@]}"; do
            if [[ $ssl_version != ${ssl_versions_output_dir[$version_out_dir]} ]]; then
                continue
            fi
            echo "Build $ssl_version"
            for arch in "${!architectures[@]}"; do
                qt_arch="${architectures[$arch]}"
                extract_package $qt_arch $version_out_dir $ssl_version
                pushd "openssl-$ssl_version" || exit 1

                log_file="build_${arch}_${ssl_version}.log"
                ndk="${ssl_versions_ndk[$ssl_version]}"
                configure_ssl "${ndk}" "${param}" ${ssl_version} ${version_out_dir} ${arch} ${log_file}

                case $version_out_dir in
                    ssl_1.1)
                        build_ssl_1_1 ${version_out_dir} ${qt_arch} ${log_file}
                        ;;
                    ssl_3)
                        build_ssl_3 ${version_out_dir} ${qt_arch} ${log_file}
                        ;;
                    *)
                        echo "Unhandled OpenSSL version $version_out_dir"
                        exit 1
                        ;;
                esac

                if [ "$arch" == "arm64" ]; then
                    echo "Update OpenSSL version $version_out_dir headers."
                    rm -fr "../$version_out_dir/include"
                    cp -a include "../$version_out_dir" || exit 1
                fi
                popd
            done
        done
        rm -fr "openssl-$ssl_version"
        rm "openssl-$ssl_version.tar.gz"
    done
    if [ "${param}" ]; then
        popd
    fi
done

# Clean include folder
find . -name "*.in" -delete
find . -name "*.def" -delete
