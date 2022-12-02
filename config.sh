#!/bin/bash

# Default values for:
# - QEMU_PATCHES_BRANCH: the name of the branch from where to extract
#                        the patches, in the patches repository;
# - QEMU_PATCHES_REPO:   the URL of the repository with the doenstream
#                        patches as commits (in the QEMU_PATCHES_BRANCH
#                        branch);
# - QEMU_PATCHES_TMPDIR: path of the temporary space for preparing the
#                        patches. Will  be wiped at the end (unless
#                        specifically asked not to);
# - QEMU_UPSTREAM_REPO:  the URL of the QEMU upstream repo, for fetching
#                        official branch and tags and use as base.
#
# The ones listed in this file are just default values. They can all be
# altered with command line parameters.

if [[ ! $QEMU_PATCHES_BRANCH ]] ; then
	QEMU_PATCHES_BRANCH="v7.1.0-factory"
	#QEMU_PATCHES_BRANCH="v7.1.0-sle15sp5"
	#QEMU_PATCHES_BRANCH="v6.2.0-sle15sp4"
	#QEMU_PATCHES_BRANCH="v5.2.0-sle15sp3"
	#QEMU_PATCHES_BRANCH="v4.2.1-sle15sp2"
	#QEMU_PATCHES_BRANCH="v3.1.1.1-sle15sp1"
	#QEMU_PATCHES_BRANCH="v2.11.2-sle15"
	#QEMU_PATCHES_BRANCH="v3.1.1.1-sle12sp5"
	#QEMU_PATCHES_BRANCH="v2.11.2-sle12sp4"
fi

if [[ ! $QEMU_PATCHES_REPO ]] ; then
	QEMU_PATCHES_REPO="https://github.com/openSUSE/qemu.git"
fi

if [[ ! $QEMU_PATCHES_TMPDIR ]] ; then
	TMPDIR=${TMPDIR:-"/tmp"}
fi

# QEMU_PATCHES_LOCAL_REPO=

if [[ ! $QEMU_UPSTREAM_REPO ]] ; then
	QEMU_UPSTREAM_REPO="https://gitlab.com/qemu-project/qemu.git"
fi

