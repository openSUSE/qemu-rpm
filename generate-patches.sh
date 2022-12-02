#!/bin/bash
#
[[ -f config.sh ]] && . config.sh

wd=$(pwd)

branch_name=$QEMU_PATCHES_BRANCH
qemu_package_repo=$QEMU_PATCHES_REPO
qemu_package_repo_name=opensuse-packaging-repo
prep_repo_only="false"
pre_cleanup_patches="true"
test_apply_patches="false"
cleanup_local_repo="true"
keep_temp_files="false"

usage() {
	echo "$0 [-b name|-t name] [[-P] -l lrepo]"
	echo
	echo "This script takes a branch of a QEMU source code repository and converts"
	echo " some of its commit in patch files. It is intended for being used while"
	echo " creating packages of QEMU, such as RPMs."
	echo
	echo "It is not necessary to have any pre-fetched or pre-configured repository,"
	echo " the script will download (and cleanup when done) everything that is necessary"
	echo " by itself. On the other hand, if the path to a local already existing"
	echo " repository is provided, it will be used (saving time and bandwidth. If such"
	echo " repository already contains the proper branches, they will also be used"
	echo " (following the assumption that this is intentional, e.g., for generating"
	echo " patches out of a local branch being used for development)."
	echo
	echo "FIXME: Add (pointers to) more detailed explanation and examples."
	echo
	echo " -b|-t name  Checks out the commits in branch or tag 'name' and turn them"
	echo "             in patches (beware that using tags may not always work)."
	echo "             If not given, default is: \'$branch_name\'."
	echo " -r rrepo    Checks out the commits from (the given branch in) 'rrepo'."
	echo "             If not given, the default is: \'$qemu_package_repo\'."
	echo " -l lrepo    Path where to clone the repositories with the commits being"
	echo "             turned into patches. If not give, a temporary location is used"
	echo "             and cleaned up completely at the end of execution."
	echo " -P          Just prepare the repository for downstream commits/patches"
	echo "             viewing or development. It only makes sense if '-l lrepo'"
	echo "             is also used."
	echo " -T          After preparing the patches out of the commits, test if they"
	echo "             can be applied cleanly."
	echo " -K          FIXME: document this option."
	echo " -R          FIXME: document this option."
	echo " -O          FIXME: ducument this option."
	echo " -h          Show this message"
	echo
	echo "Default values are defined in the config file 'config.sh' and can also be altered"
	echo "acting on the following environment variables:"
	echo "FIXME: Document environment variables"
}

while [[ "$1" != "" ]] ; do
	case "$1" in
	-t|--tag|-b|--branch)
		branch_name=$2
		shift 2
		;;
	-r|--repo)
		qemu_package_repo=$2
		qemu_package_repo_name=$(echo $qemu_package_repo | sed -E 's/(https:\/\/){0,1}(.*@){0,1}(.*)/\3/' | tr '/' '-' | tr '.' '_')
		shift 2
		;;
	-l|--local-repo)
		QEMU_PATCHES_LOCAL_REPO=$2
		cleanup_local_repo="onerror"
		shift 2
		;;
	-P|--repo-prep-only)
		prep_repo_only="true"
		shift
		;;
	-T|--test-apply-patches)
		test_apply_patches="true"
		shift
		;;
	-K|--keep-temp-files)
		keep_temp_files="true"
		cleanup_local_repo="false"
		shift
		;;
	-O|--output-dir)
		wd=$2
		shift 2
		;;
	-R|--upstream-repo)
		QEMU_UPSTREAM_REPO=$2
		shift 2
		;;
	-h|--help)
		echo "Usage:"
		usage
		exit 0
		;;
	*)
		echo "ERROR: Unsupported syntax or option"
		usage
		exit 2
		;;
	esac
done

if [[ "$prep_repo_only" == "true" ]] && [[ ! $QEMU_PATCHES_LOCAL_REPO ]] ; then
	echo "ERROR: -P for preparing the repo does not make sense without also telling where to put it!"
	exit 2
fi

pd=$(realpath "${wd}/patches")
TMPDIR=$(mktemp -d ${TMPDIR}/qemu-${branch_name}-XXXX)

if [[ $QEMU_PATCHES_LOCAL_REPO ]] ; then
	qd=$(realpath $QEMU_PATCHES_LOCAL_REPO)
else
	qd=${TMPDIR}/qemu-opensuse
fi

cleanup() {
	[[ "$cleanup_local_repo" == "onerror" ]] && [[ $? -ne 0 ]] && cleanup_local_repo="true"
	[[ "$cleanup_local_repo" == "true" ]] && rm -rf $qd
	if [[ "$keep_temp_files" == "false" ]] ; then
		rm -rf ${TMPDIR}
		rm -rf $pd
	fi
}
trap cleanup EXIT

# If we're using a local git repo, e.g., because we're developing/testing
# manipulating the patches, stay in it. If not, we're probably just refreshing
# the patches archive for the RPM, so let's temporarily checkout the the online
# one. Let's also make sure we have the upstream and the packaging repo as
# remotes.
#
# TODO: We should check if the remotes are there already but, for now, let's
#       just go straight to adding them. It may fail (if indeed they're there),
#       but it's not a big deal.
if [[ ! -d $qd ]] ; then
	# FIXME [0]: I was doing `git clone --recurse-submodules
	#            $qemu_package_repo $qd` but then submodules are not
	#            properly updated when I switch branch. That should not
	#            happen, but while we try to understand why, let's just
	#            delay fetching them. See also [1] and [2] below.
	git clone $qemu_package_repo $qd
	git -C $qd remote rename origin $qemu_package_repo_name
else
	git -C $qd remote add $qemu_package_repo_name $qemu_package_repo
	# Never remove a pre-existing repo!
	cleanup_local_repo="false"
fi
# TODO: In theory, if remotes with these names are there already: 1) these
#       commands will fail (but that's fine) and 2) we'll just use them. It
#       would be good to at least check they point to what we want, and maybe
#       fixup them if they don't (this, of course, apply only to the case
#       of a pre-existing local repo).
git -C $qd remote add upstream $QEMU_UPSTREAM_REPO
git -C $qd remote update

# Now we deal with the branch. If it already exist locally, we want to go for
# it. If not, the best that we can do is try to check if it's there in any of
# the configured remote. If that's not the case either, we just fail.
git_pull_command="pull"
if ! git -C $qd branch | grep -qE "^(\*){0,}[[:space:]]{0,}${branch_name}$" ; then
	branch_remote=$(git -C $qd branch -r | grep -E "^[[:space:]]{2}[^/]*/${branch_name}$")
	if [[ ! $branch_remote ]] && git -C $qd tag | grep -q ^${branch_name}$ ; then
		# No suitable branch. Can it be that it's a tag name that
		# we've been given? Let's see. And if yes, let's also try to
		# use it (with some caveats, such as... 
		branch_remote=$branch_name
		# ...we won't be able to do `git pull`-s for tags).
		git_pull_command="-v"
	fi
	if [[ ! $branch_remote ]] ; then
		echo -n "ERROR: $branch_name cannot be found neither in $qd nor in any remote (including $qemu_package_repo)"
		exit 1
	fi
	# FIXME [1]: A said above in [0], when switching to a branch, submodules
	#            should also switch to their corresponding branch, as configured
	#            in .gitmodules (which we patch). As a matter of fact, this does
	#            not really happen, and I'm not sure why. Let's try a full
	#            deinit/init cycle, to see if the proper branch is picked up,
	#            but that also does not happear to always work, and requires
	#            further investigation...
	git -C $qd submodule_deinit -f --all
	if ! git -C $qd checkout -b $branch_name $branch_remote ; then
		echo "ERROR: cannot checkout $branch_remote into branch $branch_name of $qd"
		exit 1
	fi
fi
# If we come from inside the above if, we're in the proper branch already. But
# maybe we don't, so let's be sure we go there.
#
# FIXME [2]: for the 'submodule deinit' part, see [1] and [0] above.
git -C $qd submodule deinit -f --all && git -C $qd checkout $branch_name && \
	git -C $qd $git_pull_command && git -C $qd submodule update --init --recursive
if [[ ! $? -eq 0 ]]; then
	echo "ERROR: $qd has a $branch_name branch, but it can't be used (it's dirty or something...)"
	exit 1
fi

# Canonical branch names are "<qemu-version-tag>-<product-name>", e.g.,
# "v7.1.0-factory" or "v6.2.0-sle15sp4". Let's assume that this is the
# case and try to derive the base QEMU version from that. Note that, if
# that's not the case, $ver can be empty!
ver=$(echo $branch_name | grep -E "v([0-9]\.){2,}[0-9]{0,}-[[:alnum:]]{1,}" | grep -Eo "([0-9]\.){2,}[0-9]{0,}")

# Let's check if all the tags and branches are there. In fact, $branch_name
# should be the current checked out branch, at this point:
if ! git -C $qd branch | grep -q "^* $branch_name$" ; then
	echo "ERROR: $qd is in the wrong branch (should have been $branch_name)"
	exit 1
fi
# About the base QEMU version, either we know that already, from $branch_name
# itself, or we must try to figure that out:
if [[ ! $ver ]] ; then
	ver=$(git -C $qd describe --tags 2> /dev/null | grep -Eo "([0-9]\.){2,}[0-9]{0,}")
fi
# And, once we know what the base QEMU version that we want is, let's make
# sure we have it reachable, typically as a tag (typicallly from the upstream
# repository)
if ! git -C $qd tag | grep -q "^v${ver}$" ; then
	echo "ERROR: cannot find tag 'v${ver}' in any remote of $qd"
	exit 1
fi

# Now we know all the pieces should be there. Let's enter the repo directory,
# so we can stop having to use '-C $qd' all the time.
pushd $qd

if [[ "$prep_repo_only" == "false" ]]; then
	# If we have a patches.tar.xz file already, and are in a repo, let's
	# assume we're in the QEMU package repo and that we want a changelog
	# automatically generated, for the changes we're making.
	if [[ -f ${wd}/patches.tar.xz ]] && [[ -d ${wd}/.git ]] ; then
		# First of all, if we want to refresh the patches, we need the
		# current archive to be "the original one", for this branch of
		# the package. If not, we may not be able to put together a
		# sensible changelog.
		pushd $wd
		if ! git status ${wd}/patches.tar.xz | grep -q "working tree clean" ; then
			echo "ERROR: ${wd}/patches.tar.xz has local modifications, cannot continue!"
			exit 1
		fi
		rm -rf $pd ; tar xf ${wd}/patches.tar.xz
		mv $pd "${pd}_old" ; mv ${wd}/patches.tar.xz ${wd}/patches_old.tar.xz
		popd
	fi
	rm -rf $pd ${wd}/patches.tar.xz ; mkdir -p $pd
	git format-patch --no-stat --no-thread -n --start-number 1 -o $pd \
		-I "Subproject commit  [a-f0-9]{40}" \
		--ignore-submodules=all --filename-max-length=128 v${ver}
	git log --oneline HEAD...v{$ver} >> ${pd}/commits.list
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
	submodule_head=$(echo $subm | cut -f1 -d' ')
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

	git checkout $submodule_branch && git $git_pull_command && git submodule update --recursive
	if [[ ! $? -eq 0 ]]; then
		echo "ERROR: ${qd}/${submodule_dir} has a $submodule_branch branch, but it can't be used (it's dirty or something...)"
		exit 1
	fi
	if [[ "$prep_repo_only" == "false" ]]; then
		git format-patch --no-stat --no-thread -n --start-number $submodule_id -o $pd \
			-I "Subproject commit  [a-f0-9]{40}" \
			--src-prefix="a/${submodule_dir}/" --dst-prefix="b/${submodule_dir}/" \
			--ignore-submodules=all --filename-max-length=128 ${submodule_head}
		git log --oneline HEAD...${submodule_head} >> ${pd}/commits.list
	fi
	popd
	submodule_id=$(($submodule_id + 1000))
done < ${TMPDIR}/qemu-submodules-patched

# Let's prepare the archive with all the patches. We'll cleanup
# the patches/ directory later, after testing if they apply (if
# that was requested).
if [[ "$prep_repo_only" == "false" ]] ; then
	pushd $wd
	ls ${pd}/ | grep '.patch$' > ${pd}/patches.list
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
	for ptch in $(ls $pd/*.patch -v1) ; do
		cat $pd/$ptch | patch -p1 -s --fuzz=0 --no-backup-if-mismatch -f
	done
	popd
fi

[[ $QEMU_PATCHES_LOCAL_REPO ]] && echo "QEMU repository for packaging ready at: $qd"
[[ "$prep_repo_only" == "false" ]] && echo "Patches ready at: $pd"
exit 0
