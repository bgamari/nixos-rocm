# All packages in the 30_rocm package set that are ready for use.

self: pkgs:

with pkgs;

{

  # The kernel
  linux_4_18_kfd = (callPackage ./os-specific/linux/kernel/linux-4.18-kfd.nix {
    buildLinux = attrs: callPackage ./os-specific/linux/kernel/generic.nix attrs;
    kernelPatches =
      [ kernelPatches.bridge_stp_helper
        kernelPatches.modinst_arg_list_too_long
      ];
    extraConfig = ''
      KALLSYMS_ALL y
      DRM_AMD_DC y
      UNUSED_SYMBOLS y
    '';
    });
  linuxPackages_rocm = recurseIntoAttrs (linuxPackagesFor self.linux_4_18_kfd);

  # Userspace ROC stack
  roct = callPackage ./development/libraries/roct.nix {};
  rocr = callPackage ./development/libraries/rocr { inherit (self) roct; };
  rocr-ext = callPackage ./development/libraries/rocr/rocr-ext.nix {};
  rocm-cmake = callPackage ./development/tools/rocm-cmake.nix {};
  rocminfo = callPackage ./development/tools/rocminfo.nix {
    inherit (self) rocm-cmake rocr;
    defaultTargets = config.rocmTargets or ["gfx803" "gfx900" "gfx906"];
  };

# I wonder if we could fetch the source for the llvm-project monorepo,
# then use subdirectories of that as the source directories for the
# individual builds.

  # ROCm LLVM, LLD, and Clang
  rocm-llvm-project = tag: sha256: fetchFromGitHub {
    owner = "RadeonOpenCompute";
    repo = "llvm-project";
    rev = "roc-${tag}-3.1.0";
    inherit sha256;
  };

  rocm-llvm-project-ocl = self.rocm-llvm-project "ocl" "05z3l14mxragd5idha75g4qpdb7pjpklzangvd3yizx36243wvzl";
  # rocm-llvm-project-hcc = self.rocm-llvm-project "hcc" "1vi7y0wxkx4q7ql2sv6qzpfip1gv6jks864b7wc7r8n96yh2wxfz";
  rocm-llvm-project-hcc = fetchFromGitHub {
    owner = "RadeonOpenCompute";
    repo = "llvm-project";
    # The roc-hcc-3.1.0 tagged revision of llvm-projects produces an
    # hcc that produces a hip that can not build rccl. This is a newer
    # revision of llvm-project that was the submodule of the hcc
    # development branch as of 20202902.
    rev = "e8173c23afae5686ccb3bf92ccc8f16c7f47023f";
    sha256 = "1nqpvvqs8cm8ihfmd4653zdp607lbzfsbbg5xnvni8pykmrfc9rd";
  };

  rocm-llvm = callPackage ./development/compilers/llvm rec {
    version = "3.1.0";
    src = "${self.rocm-llvm-project-ocl}/llvm";
  };
  rocm-lld = self.callPackage ./development/compilers/lld rec {
    name = "rocm-lld";
    version = "3.1.0";
    src = "${self.rocm-llvm-project-ocl}/lld";
    llvm = self.rocm-llvm;
  };
  rocm-clang-unwrapped = callPackage ./development/compilers/clang rec {
    name = "clang-unwrapped";
    version = "3.1.0";
    src = "${self.rocm-llvm-project-ocl}/clang";
    llvm = self.rocm-llvm;
    lld = self.rocm-lld;
    inherit (self) rocr;
  };
  rocm-clang = pkgs.wrapCCWith rec {
    cc = self.rocm-clang-unwrapped;
    extraPackages = [ libstdcxxHook ];
    extraBuildCommands = ''
      rsrc="$out/resource-root"
      mkdir "$rsrc"
      ln -s "${cc}/lib/clang/11.0.0/include" "$rsrc"
      echo "-resource-dir=$rsrc" >> $out/nix-support/cc-cflags
      echo "--gcc-toolchain=${stdenv.cc.cc}" >> $out/nix-support/cc-cflags
      echo "-Wno-unused-command-line-argument" >> $out/nix-support/cc-cflags
      rm $out/nix-support/add-hardening.sh
      touch $out/nix-support/add-hardening.sh
    '';
  };

  # OpenCL stack
  rocm-device-libs = callPackage ./development/libraries/rocm-device-libs {
    inherit (self) rocr;
    stdenv = pkgs.overrideCC stdenv self.rocm-clang;
    llvm = self.rocm-llvm;
    clang = self.rocm-clang;
    lld = self.rocm-lld;
    tagPrefix = "roc-ocl";
    sha256 = "0c5a3ag763jr1nyvf9s3xlnf0hgx2i4hls2ab95kg65mkx7cyr02";
  };
  # rocm-opencl-driver = callPackage ./development/libraries/rocm-opencl-driver {
  #   stdenv = pkgs.overrideCC stdenv self.rocm-clang;
  #   inherit (self) rocm-lld rocm-llvm rocm-clang-unwrapped;
  # };
  rocm-ocl-comgr = (callPackage ./development/libraries/comgr {
    llvm = self.rocm-llvm;
    lld = self.rocm-lld;
    clang = self.rocm-clang;
    device-libs = self.rocm-device-libs;
  });

  rocm-opencl-runtime = callPackage ./development/libraries/rocm-opencl-runtime.nix {
    stdenv = pkgs.overrideCC stdenv self.rocm-clang;
    inherit (self) roct rocm-clang rocm-clang-unwrapped rocm-cmake;
    inherit (self) rocm-device-libs rocm-lld rocm-llvm rocr;
    comgr = self.rocm-ocl-comgr;
  };
  rocm-opencl-icd = callPackage ./development/libraries/rocm-opencl-icd.nix {
    inherit (self) rocm-opencl-runtime;
  };

  # HCC

  # hcc relies on submodules for llvm, clang, and compiler-rt at
  # specific revisions that do not track ROCm releases. We break the
  # hcc build into parts to make it a bit more manageable when dealing
  # with failures, and to have an opportunity to wrap hcc-clang before
  # hcc tools are built using that compiler.
  hcc-llvm = callPackage ./development/compilers/llvm rec {
    name = "hcc-llvm";
    version = "3.1.0";
    src = "${self.rocm-llvm-project-hcc}/llvm";
  };
  hcc-lld = callPackage ./development/compilers/lld {
    name = "hcc-lld";
    version = "3.1.0";
    src = "${self.rocm-llvm-project-hcc}/lld";
    llvm = self.hcc-llvm;
  };
  hcc-clang-unwrapped = callPackage ./development/compilers/hcc-clang {
    inherit (self) rocr rocminfo hcc-llvm hcc-lld;
    version = "3.1.0";
    src = "${self.rocm-llvm-project-hcc}/clang";
  };
  hcc-clang = pkgs.wrapCCWith rec {
    cc = self.hcc-clang-unwrapped;
    extraPackages = [ libstdcxxHook ];
    extraBuildCommands = ''
      rsrc="$out/resource-root"
      mkdir "$rsrc"
      ln -s "${cc}/lib/clang/11.0.0/include" "$rsrc"
      echo "-resource-dir=$rsrc" >> $out/nix-support/cc-cflags
      echo "--gcc-toolchain=${stdenv.cc.cc}" >> $out/nix-support/cc-cflags
      rm $out/nix-support/add-hardening.sh
      touch $out/nix-support/add-hardening.sh
    '';
  };

  hcc-compiler-rt = callPackage ./development/compilers/hcc-compiler-rt {
    src = "${self.rocm-llvm-project-hcc}/compiler-rt";
    llvm = self.hcc-llvm;
    namePrefix = "hcc";
  };
  hcc-device-libs = callPackage ./development/libraries/rocm-device-libs {
    inherit (self) rocr;
    stdenv = pkgs.overrideCC stdenv self.hcc-clang;
    llvm = self.hcc-llvm;
    clang = self.hcc-clang;
    lld = self.hcc-lld;
    tagPrefix = "roc-hcc";
    sha256 = "1f4jl14164g2x4iqmiaj284msdp12qj4fin5ks0jsqiwgv6fnjna";
  };

  # Now we build hcc itself using hcc-llvm, hcc-clang, and hcc-compiler-rt
  hcc-unwrapped = callPackage ./development/compilers/hcc {
    inherit (self) rocr rocminfo;
    lld = self.hcc-lld;
    llvm = self.hcc-llvm;
    clang-unwrapped = self.hcc-clang-unwrapped;
    clang = self.hcc-clang;
    device-libs = self.hcc-device-libs;
    compiler-rt = self.hcc-compiler-rt;
  };

  hcc = pkgs.wrapCCWith rec {
    isClang = true;
    cc = self.hcc-clang-unwrapped;
    extraPackages = [ libstdcxxHook self.hcc-unwrapped ];
    extraBuildCommands = ''
      echo "-resource-dir=${self.hcc-clang}/resource-root" >> $out/nix-support/cc-cflags
      echo "--gcc-toolchain=${stdenv.cc.cc}" >> $out/nix-support/cc-cflags
      ln -s $out/bin/clang++ $out/bin/hcc
      for f in $(find ${self.hcc-unwrapped}/bin); do
        if [ ! -f $out/bin/$(basename "$f") ]; then
          ln -s "$f" $out/bin
        fi
      done
      mkdir -p $out/include
      ln -s ${self.hcc-unwrapped}/include $out/include/hcc
      ln -s ${self.hcc-unwrapped}/include/* $out/include/
      rm $out/nix-support/add-hardening.sh
      touch $out/nix-support/add-hardening.sh
    '';
  };

  hcc-comgr = (callPackage ./development/libraries/comgr {
    llvm = self.hcc-llvm;
    lld = self.hcc-lld;
    clang = self.hcc-clang;
    device-libs = self.hcc-device-libs;
  }).overrideAttrs (old: {
    src = pkgs.fetchFromGitHub {
      # We need a version newer than 3.1.0 for compatibility with a
      # newer llvm
      owner = "RadeonOpenCompute";
      repo = "ROCm-CompilerSupport";
      rev = "7ac2e34f13eb3fc7bdf5211a487726084eb4e906";
      sha256 = "03i21jiqykxnkwbqkcb2ay2ss94qm6bk1x42ngha5v7827h1wdzc";
    };
  });

  # HIP

  hip = callPackage ./development/compilers/hip {
    inherit (self) roct rocr rocminfo hcc hcc-unwrapped;
    comgr = self.hcc-comgr;
  };

  hcc-openmp = pkgs.llvmPackages_latest.openmp.override {
    llvm = self.hcc-llvm;
  };

  # HIP's clang backend requires the `amd-common` branches of the
  # LLVM, LLD, and Clang forks.

  # hip-clang's build instructions do not pin a revision, and imply
  # that one ought to pull from the master branch of the upstream LLVM
  # project.
  amd-llvm-project = fetchFromGitHub {
    owner = "llvm";
    repo = "llvm-project";
    rev = "e63a3b445ac032d0b6fe7d3d1e1d8be7f9cb310b";
    sha256 = "1vh0sm2j5qxwk661j6vljp9j2n0hr8qr8nhs25m17pq0v1gkcghy";
  };

  amd-llvm = callPackage ./development/compilers/llvm rec {
    name = "amd-llvm";
    version = "20200228";
    src = "${self.amd-llvm-project}/llvm";
  };

  amd-lld = callPackage ./development/compilers/lld {
    name = "amd-lld";
    version = self.amd-llvm.version;
    src = "${self.amd-llvm-project}/lld";
    llvm = self.amd-llvm;
  };

  amd-openmp = pkgs.llvmPackages_latest.openmp.override {
    llvm = self.amd-llvm;
  };

  amd-compiler-rt = callPackage ./development/compilers/hcc-compiler-rt {
    src = "${self.amd-llvm-project}/compiler-rt";
    llvm = self.amd-llvm;
    namePrefix = "amd";
  };

  amd-clang-unwrapped = (callPackage ./development/compilers/clang {
    name = "amd-clang";
    version = self.amd-llvm.version;
    src = "${self.amd-llvm-project}/clang";
    inherit (self) rocr;
    llvm = self.amd-llvm;
    lld = self.amd-lld;
  }).overrideAttrs(_: {
    # HIP assumes LLVM and LLD binaries are in its own binary directory
    postPatch = ''
      sed -e 's,  SmallString<128> ExecPath(C.getDriver().Dir);,  SmallString<128> ExecPath("${self.amd-llvm}/bin");,' \
          -e 's,  SmallString<128> OptPath(C.getDriver().Dir);,  SmallString<128> OptPath("${self.amd-llvm}/bin");,' \
          -e 's,  SmallString<128> LlcPath(C.getDriver().Dir);,  SmallString<128> LlcPath("${self.amd-llvm}/bin");,' \
          -e 's,  SmallString<128> LldPath(C.getDriver().Dir);,  SmallString<128> LldPath("${self.amd-lld}/bin");,' \
          -e "s,  SmallString<128> BundlerPath(C.getDriver().Dir);,  SmallString<128> BundlerPath(\"$out/bin\");," \
          -i lib/Driver/ToolChains/HIP.cpp
    '';
  });

  # Wrap clang so it is a usable compiler
  amd-clang = pkgs.wrapCCWith rec {
    isClang = true;
    cc = self.amd-clang-unwrapped;
    extraPackages = [ libstdcxxHook self.amd-clang-unwrapped ];
    extraBuildCommands = ''
      rsrc="$out/resource-root"
      mkdir "$rsrc"
      ln -s "${cc}/lib/clang/11.0.0/include" "$rsrc"
      echo "-resource-dir=$rsrc" >> $out/nix-support/cc-cflags
      echo "--gcc-toolchain=${stdenv.cc.cc}" >> $out/nix-support/cc-cflags
      echo "-Wno-unused-command-line-argument" >> $out/nix-support/cc-cflags
      rm $out/nix-support/add-hardening.sh
      touch $out/nix-support/add-hardening.sh
    '';
  };

  amd-device-libs = callPackage ./development/libraries/rocm-device-libs {
    inherit (self) rocr;
    stdenv = pkgs.overrideCC stdenv self.amd-clang;
    llvm = self.amd-llvm;
    clang = self.amd-clang;
    lld = self.amd-lld;
    source = pkgs.fetchFromGitHub {
      owner = "RadeonOpenCompute";
      repo = "ROCm-Device-Libs";
      rev = "c214a58482cab30fd3cdf9cc6fda5bd432aa2f9e";
      sha256 = "19g5w5l3yizli0zk26gpl5i798n6zaj95hsczspm9432w01lxsgw";
    };
  };

  amd-comgr = (callPackage ./development/libraries/comgr {
    llvm = self.amd-llvm;
    lld = self.amd-lld;
    clang = self.amd-clang;
    device-libs = self.amd-device-libs;
  }).overrideAttrs (old: {
    src = pkgs.fetchFromGitHub {
      # We need a version newer than 3.1.0 for compatibility with the
      # newer amd-llvm
      owner = "RadeonOpenCompute";
      repo = "ROCm-CompilerSupport";
      rev = "7ac2e34f13eb3fc7bdf5211a487726084eb4e906";
      sha256 = "03i21jiqykxnkwbqkcb2ay2ss94qm6bk1x42ngha5v7827h1wdzc";
    };
  });

  # A HIP compiler that does not go through hcc
  hip-clang = callPackage ./development/compilers/hip-clang {
    inherit (self) roct rocr rocminfo hcc;
    llvm = self.amd-llvm;
    clang-unwrapped = self.amd-clang-unwrapped;
    clang = self.amd-clang;
    device-libs = self.amd-device-libs;
    comgr = self.amd-comgr;
  };

  clang-ocl = callPackage ./development/compilers/clang-ocl {
    inherit (self) rocm-cmake rocm-device-libs rocm-lld rocm-llvm;
    inherit (self) hcc rocm-opencl-runtime;
    # inherit (self) amd-clang amd-clang-unwrapped;
    inherit (pkgs.llvmPackages_10) clang clang-unwrapped;
  };

  rocm-smi = callPackage ./tools/rocm-smi { };

  rocm-bandwidth = callPackage ./tools/rocm-bandwidth {
    inherit (self) roct rocr;
  };

  rocblas-tensile = callPackage ./development/libraries/rocblas/tensile.nix {
    inherit (python3Packages) buildPythonPackage pyyaml pytest;
    inherit (self) rocminfo hcc rocm-smi;
  };

  rocblas = callPackage ./development/libraries/rocblas {
    inherit (self) rocm-cmake hcc hcc-unwrapped rocr rocblas-tensile;
    hip = self.hip;
    clang = self.hcc-clang;
    openmp = self.hcc-openmp;
    comgr = self.amd-comgr;
    llvm = pkgs.llvmPackages_6.llvm;
    inherit (python3Packages) python;
  };

  # MIOpen

  miopengemm = callPackage ./development/libraries/miopengemm {
    inherit (self) rocm-cmake rocm-opencl-runtime hcc;
  };

  # Currently broken
  miopen-cl = callPackage ./development/libraries/miopen {
    inherit (self) rocm-cmake rocm-opencl-runtime rocr hcc
                   clang-ocl miopengemm rocblas;
    hip = self.hip;
    clang = self.hcc-clang;
    comgr = self.amd-comgr;
  };

  miopen-hip = self.miopen-cl.override {
    useHip = true;
  };

  rocfft = callPackage ./development/libraries/rocfft {
    inherit (self) rocr rocminfo hcc rocm-cmake;
    hip = self.hip;
    clang = self.hcc-clang;
    comgr = self.amd-comgr;
  };

  rccl = callPackage ./development/libraries/rccl {
    inherit (self) rocm-cmake hcc;
    hip = self.hip;
    comgr = self.amd-comgr;
  };

  rocrand = callPackage ./development/libraries/rocrand {
    inherit (self) rocm-cmake rocminfo hcc rocr;
    comgr = self.amd-comgr;
    hip = self.hip;
  };
  rocrand-python-wrappers = callPackage ./development/libraries/rocrand/python.nix {
    inherit (self) rocr rocrand;
    inherit (python3Packages) buildPythonPackage numpy;
    hip = self.hip;
  };

  rocprim = callPackage ./development/libraries/rocprim {
    inherit (self) rocm-cmake rocr;
    stdenv = pkgs.overrideCC stdenv self.hcc;
    hip = self.hip;
  };

  hipcub = callPackage ./development/libraries/hipcub {
    inherit (self) hcc hip rocm-cmake rocprim;
  };

  rocsparse = callPackage ./development/libraries/rocsparse {
    inherit (self) rocprim hipcub rocm-cmake hcc;
    hip = self.hip;
    comgr = self.amd-comgr;
  };

  hipsparse = callPackage ./development/libraries/hipsparse {
    inherit (self) rocr rocsparse rocm-cmake hcc;
    hip = self.hip;
    comgr = self.amd-comgr;
  };

  rocthrust = callPackage ./development/libraries/rocthrust {
    inherit (self) rocm-cmake rocprim hcc;
    hip = self.hip;
    comgr = self.amd-comgr;
  };

  roctracer = callPackage ./development/tools/roctracer {
    inherit (self) hcc-unwrapped roct rocr;
    hip = self.hip;
    inherit (pkgs.pythonPackages) python buildPythonPackage fetchPypi ply;
  };

  rocprofiler = callPackage ./development/tools/rocprofiler {
    inherit (self) rocr roct roctracer hcc-unwrapped;
  };

  amdtbasetools = callPackage ./development/libraries/AMDTBaseTools {};
  amdtoswrappers = callPackage ./development/libraries/AMDTOSWrappers {
    inherit (self) amdtbasetools;
  };
  cxlactivitylogger = callPackage ./development/libraries/cxlactivitylogger {
    inherit (self) amdtbasetools amdtoswrappers;
  };

  clpeak = pkgs.callPackage ./tools/clpeak {
    opencl = self.rocm-opencl-runtime;
  };

  tensorflow-rocm = python37Packages.callPackage ./development/libraries/tensorflow/bin.nix {
    inherit (self) hcc hcc-unwrapped miopen-hip miopengemm rocrand
                   rocfft rocblas rocr rccl cxlactivitylogger;
    hip = self.hip;
  };

  tensorflow2-rocm = python37Packages.callPackage ./development/libraries/tensorflow/bin2.nix {
    inherit (self) hcc hcc-unwrapped miopen-hip miopengemm rocrand
                   rocfft rocblas rocr rccl cxlactivitylogger;
    hip = self.hip;
  };

  pytorch-rocm = python37Packages.callPackage ./development/libraries/pytorch/default.nix {
    inherit (self) rocr miopengemm rocsparse hipsparse rocthrust
      rccl rocrand rocblas rocfft rocprim hipcub roctracer rocm-cmake;
    miopen = self.miopen-hip;
    hip = self.hip;
    comgr = self.amd-comgr;
    openmp = self.hcc-openmp;
    hcc = self.hcc-unwrapped;
  };

  torchvision-rocm = python37Packages.torchvision.override {
    pytorch = self.pytorch-rocm;
  };

  # The OpenCL compiler (called through clBuildProgram by darktable)
  # is not properly supporting `-I` flags to add to the include
  # path. To avoid relying on that mechanism, we edit `#include`
  # directives in the OpenCL kernels to use absolute paths.
  darktable-rocm = pkgs.darktable.overrideAttrs (old: {
    preFixup = (old.preFixup or "") + ''
      for f in $(find $out/share/darktable/kernels -name '*.cl'); do
        sed "s|#include \"\(.*\)\"|#include \"$out/share/darktable/kernels/\1\"|g" -i "$f"
      done
    '';
  });

  rocm-llvm-project-aomp = fetchFromGitHub {
    owner = "ROCm-Developer-Tools";
    repo = "llvm-project";
    rev = "roc-aomp-3.0.0";
    sha256 = "00cw8azj2jh7zs79klk6zcrw76dkiplrignazl9lavyr9qcbiy7v";
  };
}
