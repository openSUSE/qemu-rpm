#!/bin/bash

branch_name="v7.1.0-factory"
#branch_name="v7.1.0-sle15sp5"
#branch_name="v6.2.0-sle15sp4"
#branch_name="v5.2.0-sle15sp3"
#branch_name="v4.2.1-sle15sp2"
#branch_name="v3.1.1.1-sle15sp1"
#branch_name="v2.11.2-sle15"
#branch_name="v3.1.1.1-sle12sp5"
#branch_name="v2.11.2-sle12sp4"

prep_repo_only="false"
pre_cleanup_patches="true"
keep_temp_files="false"
test_apply_patches="false"

QEMU_UPSTREAM_REPO=${UPSTREAM_GIT_REPO:-https://gitlab.com/qemu-project/qemu.git}
QEMU_PACKAGE_REPO=${PACKAGE_GIT_REPO:-https://github.com/openSUSE/qemu.git}
# QEMU_PACKAGE_LOCAL_REPO=
TMPDIR=${TMPDIR:-"/tmp"}
