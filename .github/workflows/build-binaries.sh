#!/bin/bash

# -x causes commands to be logged before invocation
# -e causes the execution to terminate as soon as any command fails
set -x -e
DEBUG=$1  # Value is '' or 'debug'
RUNNER_OS=$2  #  ${{ runner.os }} is Linux, Windiws, maxOS
TAG=$3 # For master it's 24.0.999, while for tag it's the tag itself
NO_REBASE=$4 # Specify this to skip the rebase over the edge branch. Used for local debugging.

prefix=/tmp/ADALIB_DIR

export CPATH=/usr/local/include
export LIBRARY_PATH=/usr/local/lib
export DYLD_LIBRARY_PATH=/usr/local/lib
export PATH=`ls -d $PWD/cached_gnat/*/bin |tr '\n' ':'`$PATH
export ADAFLAGS=-g1

if [ $RUNNER_OS = Windows ]; then
    prefix=/opt/ADALIB_DIR
    export CPATH=`cygpath -w /c/msys64/mingw64/include`
    export LIBRARY_PATH=`cygpath -w /c/msys64/mingw64/lib`
    mount D:/opt /opt
fi

export GPR_PROJECT_PATH=$prefix/share/gpr:\
$PWD/subprojects/VSS/gnat:\
$PWD/subprojects/gnatdoc/gnat:\
$PWD/subprojects/lal-refactor/gnat:\
$PWD/subprojects/libadalang-tools/src:\
$PWD/subprojects/spawn/gnat:\
$PWD/subprojects/stubs
echo PATH=$PATH

BRANCH=master

# Rebase PR on edge branch
if [[ -z "$NO_REBASE" && ${GITHUB_REF##*/} != 2*.[0-9]*.[0-9]* ]]; then
    git config user.email "`git log -1 --pretty=format:'%ae'`"
    git config user.name  "`git log -1 --pretty=format:'%an'`"
    git config core.autocrlf
    git config core.autocrlf input
    git rebase --verbose origin/edge
fi

# Audit the npm packages
cd integration/vscode/ada
npm install
# Run npm audit to check for any vulnerabilities
npm audit
cd -

# Get libadalang binaries
mkdir -p $prefix
FILE=libadalang-$RUNNER_OS-$BRANCH${DEBUG:+-dbg}-static.tar.gz
# If the script is run locally for debugging, it is not always possible
# to download libadalang from AWS S3. Instead, allow for the file to
# be obtained otherwise and placed in the current directory for the script
# to use. Thus, if the file is already there, we don't download it again
# and we don't delete it after use.
if [ ! -f "$FILE" ]; then
   aws s3 cp s3://adacore-gha-tray-eu-west-1/libadalang/$FILE . --sse=AES256
   umask 0 # To avoid permission errors on MSYS2
   tar xzf $FILE -C $prefix
   rm -f -v $FILE
else
   # Untar the existing file and don't delete it
   tar xzf $FILE -C $prefix
fi

which python3
which pip3
pip3 install --user e3-testsuite
python3 -c "import sys;print('e3' in sys.modules)"

if [ "$DEBUG" = "debug" ]; then
    export BUILD_MODE=dev
else
    export BUILD_MODE=prod
fi

# Log info about the compiler and library paths
gnatls -v

make -C subprojects/templates-parser setup prefix=$prefix \
 ENABLE_SHARED=no \
 ${DEBUG:+BUILD=debug} build-static install-static

make LIBRARY_TYPE=static VERSION=$TAG all check

function fix_rpath ()
{
    for R in `otool -l $1 |grep -A2 LC_RPATH |awk '/ path /{ print $2 }'`; do
        install_name_tool -delete_rpath $R $1
    done
    install_name_tool -change /usr/local/opt/gmp/lib/libgmp.10.dylib @rpath/libgmp.10.dylib $1
    install_name_tool -add_rpath @executable_path $1
}

# Get architecture and platform information from node.
NODE_ARCH=$(node -e "console.log(process.arch)")
NODE_PLATFORM=$(node -e "console.log(process.platform)")
ALS_EXEC_DIR=integration/vscode/ada/$NODE_ARCH/$NODE_PLATFORM

if [ $RUNNER_OS = macOS ]; then
    cp -v -f /usr/local/opt/gmp/lib/libgmp.10.dylib $ALS_EXEC_DIR
    fix_rpath $ALS_EXEC_DIR/ada_language_server
fi

if [ "$DEBUG" != "debug" ]; then
    cd $ALS_EXEC_DIR
    if [ $RUNNER_OS = Windows ]; then
        ALS=ada_language_server.exe
    else
        ALS=ada_language_server
    fi
    if [ $RUNNER_OS = macOS ]; then
        # On macOS using objcopy from binutils to strip debug symbols to a
        # separate file doesn't work. Namely, the last step `objcopy
        # --add-gnu-debuglink` yields an executable that crashes at startup.
        #
        # Instead we use dsymutil and strip which are commands provided by the
        # system (or by XCode).
        dsymutil "$ALS"
        strip "$ALS"
    else
        objcopy --only-keep-debug ${ALS} ${ALS}.debug
        objcopy --strip-all ${ALS}
        objcopy --add-gnu-debuglink=${ALS}.debug ${ALS}
    fi
    cd -
fi
