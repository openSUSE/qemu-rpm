#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (c) 2022 SUSE LLC
#
# This script free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2
# as published by the Free Software Foundation.
#
# It is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public
# License for more details.
#
# For a copy of the GNU General Public License see:
# <http://www.gnu.org/licenses/>.
#
[[ -f config.sh ]] && . config.sh

wd=$(pwd)

while [[ "$1" != "" ]] ; do
	case "$1" in
	-u|--upstream-repo)
		QEMU_UPSTREAM_REPO=$2
		shift 2
		;;
	-l|--local-repo)
		QEMU_PACKAGE_LOCAL_REPO=$2
		shift 2
		;;
	-b|--branch)
		branch_name=$2
		shift 2
		;;
	-r|--repo)
		qemu_package_repo=$2
		qemu_package_repo_name=$(echo $qemu_package_repo | sed -E 's/(https:\/\/){0,1}(.*@){0,1}(.*)/\3/' | tr '/' '-' | tr '.' '_')
		shift 2
		;;
	-p|--package-repo)
		QEMU_PACKAGE_REMOTE_REPO=$2
		shift 2
		;;
	-O|--output-dir)
		wd=$2
		shift 2
		;;
	-P|--prep-only)
		prep_repo_only="true"
		shift
		;;
	-K|--keep-temp-files)
		keep_temp_files="true"
		shift
		;;
	-T|--test-apply-patches)
		test_apply_patches="true"
		shift
		;;
	-h|--help)
		echo "Usage:"
		exit 0
		;;
	*)
		echo "ERROR: Unsupported syntax or option"
		exit 2
		;;
	esac
done

cleanup() {
	rm -rf $pd
	[[ "$keep_temp_files" == "false" ]] && rm -rf ${TMPDIR}
}

# Canonical branch names are "<qemu-version-tag>-<product-name>", e.g.,
# "v7.1.0-factory" or "v6.2.0-sle15sp4". Let's assume that this is the
# case and try to derive the base QEMU version from that. Note that, if
# that's not the case, $ver can be empty!
ver=$(echo $branch_name | grep -E "v([0-9]\.){2,}[0-9]{0,}-[[:alnum:]]{1,}" | grep -Eo "([0-9]\.){2,}[0-9]{0,}")
pd=$(realpath "${wd}/patches")
TMPDIR=$(mktemp -d ${TMPDIR}/qemu-${branch_name}-XXXX)

if [[ ! -z $QEMU_PACKAGE_LOCAL_REPO ]] ; then
	qd=$(realpath $QEMU_PACKAGE_LOCAL_REPO)
else
	qd=${TMPDIR}/qemu-opensuse
fi

trap cleanup EXIT

# If we're using a local git repo, e.g., because we're developing/testing
# manipulating the patches, stay in it. If not, we're probably just refreshing
# the patches archive for the RPM, so let's temporarily checkout the the online
# one.
#
# Let's also make sure we have upstream, the packaging repo and the repo passed
# via the command line (if any) as remotes.
#
# TODO: We should check if the remotes are there already but, for now, let's
#       just go straight to adding them. It may fail (if indeed they're there),
#       but it's not a big deal.
if [[ ! -d $qd ]] ; then
	# XXX git clone --recurse-submodules $QEMU_PACKAGE_REPO $qd
	git clone $QEMU_PACKAGE_REPO $qd
	git -C $qd remote rename origin opensuse-packaging-repo
else
	git -C $qd remote add opensuse-packaging-repo "$QEMU_PACKAGE_REMOTE_REPO"
fi
git -C $qd remote add upstream $QEMU_UPSTREAM_REPO
[[ $qemu_package_repo ]] && git -C $qd remote add $qemu_package_repo_name $qemu_package_repo
git -C $qd remote update

# Now we deal with the branch. If it already exist locally, we want to go for
# it. If not, the best that we can do is try to check if it's there in any of
# the configured remote. If that's not the case either, we just fail.
if ! git -C $qd branch | grep -qE "^(\*){0,}[[:space:]]{0,}${branch_name}$" ; then
	branch_remote=$(git -C $qd branch -r | grep -E "^[[:space:]]{2}.*/${branch_name}$")
	if [[ ! $branch_remote ]] ; then
		echo -n "ERROR: $branch_name cannot be found neither in $qd nor in any remote (including $QEMU_PACKAGE_REMOTE_REPO"
		[[ $qemu_package_repo ]] && echo -n " or $qemu_package_repo"
		echo ")"
		exit 1
	fi
	if ! git -C $qd checkout -b $branch_name $branch_remote ; then
		echo "ERROR: cannot checkout $branch_remote into branch $branch_name of $qd"
		exit 1
	fi
fi
git -C $qd checkout $branch_name && git -C $qd pull && git -C $qd submodule update --init --recursive
if [[ ! $? -eq 0 ]]; then
	echo "ERROR: $qd has a $branch_name branch, but it can't be used (it's dirty or something...)"
	exit 1
fi

# Let's check if all the tags and branches are there. In fact, $branch_name
# should be the current checked out branch, at this point:
if ! git -C $qd branch | grep -q "^* $branch_name$" ; then
	echo "ERROR: $qd is in the wrong branch (should have been $branch_name)"
	exit 1
fi
# About the base QEMU version, either we know that already, from $branch_name
# itself, or we must try to figure that out:
if [[ ! $ver ]] ; then
	ver=$(git -C $qd describe --tags | grep -Eo "([0-9]\.){2,}[0-9]{0,}")
fi
if ! git -C $qd tag | grep -q "^v${ver}$" ; then
	echo "ERROR: cannot find tag 'v${ver}' in any remote of $qd"
	exit 1
fi

pushd $qd

if [[ "$prep_repo_only" == "false" ]]; then
	rm -rf $pd ${wd}/patches.tar.xz ; mkdir -p $pd
	git format-patch --no-stat --no-thread -n --start-number 1 -o $pd \
		-I "Subproject commit  [a-f0-9]{40}" \
		--ignore-submodules=all --filename-max-length=128 v${ver}
fi

# We want to know which submodules have patches applied (in $branch_name, of
# course) that make them diverge from their upstream status. In order to be
# able to figure that out, we extract the hash of the head of each submodule,
# with `git submodule status`, with the upstream base version branch checked
# out. See below, for how we generate the actual list.
#
# While there, we also stash the .gitmodules file. It will be useful for
# retrieving the URL of the upstream repository of the changing submodules.
git checkout --recurse-submodules v${ver}
git submodule status --recursive | awk '{print $1 " " $2}' > ${TMPDIR}/qemu-submodules-${ver}
cp .gitmodules ${TMPDIR}/qemu-gitmodules-${ver}

# In order to be able to know which submodules have changes applied, we save
# the output of `git submodule status` again, but this time while in
# $branch_name.
git checkout --recurse-submodules $branch_name
git submodule status --recursive | awk '{print $1 " " $2}' > ${TMPDIR}/qemu-submodules-${branch_name}

# Now we diff the two outputs, and the result is the lines corresponding to
# the submodules for which their head commits were different between the
# base version and $branch_name. Also, for these ones, the head of the base
# version commit (within the submodule) against which we want to run
# git-format-patch.
diff ${TMPDIR}/qemu-submodules-${ver} ${TMPDIR}/qemu-submodules-${branch_name} | \
	grep ^\< | \
	awk '{print $2 " " $3}' > ${TMPDIR}/qemu-submodules-patched
submodule_id=1000
while read -r subm ; do
	submodule_dir=$(echo $subm | cut -f2 -d' ')
	subh=$(echo $subm | cut -f1 -d' ')
	submodule_repo=$(grep -A10 submodule.*\"$submodule_dir\" .gitmodules | grep url | head -n1 | awk '{print  $3}')
	submodule_upstream_repo=$(grep -A10 submodule.*\"$submodule_dir\" ${TMPDIR}/qemu-gitmodules-${ver} | grep url | head -n1 | awk '{print  $3}')
	submodule_branch=$(grep -A10 submodule.*\"$submodule_dir\" .gitmodules | grep branch | head -n1 | awk '{print  $3}')

	pushd $submodule_dir

	git remote add opensuse-packaging-repo $submodule_repo
	git remote add upstream $submodule_upstream_repo
	git remote update

	if ! git branch | grep -qE "^(\*){0,}[[:space:]]{0,}${submodule_branch}$" ; then
		git checkout -b $submodule_branch opensuse-packaging-repo/${submodule_branch}
	fi

	git checkout $submodule_branch && git pull && git submodule update --recursive
	if [[ ! $? -eq 0 ]]; then
		echo "ERROR: ${qd}/${submodule_dir} has a $submodule_branch branch, but it can't be used (it's dirty or something...)"
		exit 1
	fi
	if [[ "$prep_repo_only" == "false" ]]; then
		git format-patch --no-stat --no-thread -n --start-number $submodule_id -o $pd \
			-I "Subproject commit  [a-f0-9]{40}" \
			--src-prefix="a/${submodule_dir}/" --dst-prefix="b/${submodule_dir}/" \
			--ignore-submodules=all --filename-max-length=128 ${subh}
	fi
	popd
	submodule_id=$(($submodule_id + 1000))
done < ${TMPDIR}/qemu-submodules-patched

# Let's prepare the archive with all the patches. We'll cleanup
# the patches/ directory later, after testing if they apply (if
# that was requested).
if [[ "$prep_repo_only" == "false" ]] ; then
	pushd $wd
	tar cJf patches.tar.xz patches
	popd
fi

popd

# Test applying the patches
if [[ "$test_apply_patches" == "true" ]]; then
	set -e
	pushd $TMPDIR
	rm -rf qemu-${ver} qemu-${ver}.tar.xz
	wget https://download.qemu.org/qemu-${ver}.tar.xz
	tar xf qemu-${ver}.tar.xz
	pushd qemu-${ver}
	for ptch in $(ls $pd -v1) ; do
		cat $pd/$ptch | patch -p1 -s --fuzz=0 --no-backup-if-mismatch -f
	done
	popd
fi

if [[ "$prep_repo_only" == "true" ]]; then
	echo "QEMU repository for packaging ready at: $qd"
else
	echo "Patches ready at: $pd"
fi
exit 0
