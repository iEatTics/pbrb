#!/bin/bash
set -eo pipefail

# SANITY CHECKS
if [[ -z $GitHubMail ]]; then echo -e "You haven't configured GitHub E-Mail Address." && exit 1; fi
if [[ -z $GitHubName ]]; then echo -e "You haven't configured GitHub Username." && exit 1; fi
if [[ -z $GITHUB_TOKEN ]]; then echo -e "You haven't configured GitHub Token.\nWithout it, recovery can't be published." && exit 1; fi
if [[ -z $MANIFEST_BRANCH ]]; then echo -e "You haven't configured PitchBlack Recovery Project Manifest Branch." && exit 1; fi
if [[ -z $VENDOR ]]; then echo -e "You haven't configured Vendor name." && exit 1; fi
if [[ -z $CODENAME ]]; then echo -e "You haven't configured Device Codename." && exit 1; fi
if [[ -z $BUILD_LUNCH && -z $FLAVOR ]]; then echo -e "Set at least one variable. BUILD_LUNCH or FLAVOR." && exit 1; fi

[[ ! -d /home/builder/.ccache ]] && mkdir -p /home/builder/.ccache
cd /home/builder/

docker run --privileged -i --name worker --user builder \
  -e USER_ID=$(id -u) -e GROUP_ID=$(id -g) \
  -e aaronrector09@gmail.com="${GitHubMail}" -e GitHubName="${GitHubName}" -e GITHUB_TOKEN="${GITHUB_TOKEN}" \
  -e CIRCLE_PROJECT_USERNAME="${CIRCLE_PROJECT_USERNAME}" -e CIRCLE_PROJECT_REPONAME="${CIRCLE_PROJECT_REPONAME}" \
  -e CIRCLE_BRANCH="${CIRCLE_BRANCH}" -e CIRCLE_SHA1="${CIRCLE_SHA1}" \
  -e MANIFEST_BRANCH="${MANIFEST_BRANCH}" -e PBRP_BRANCH="${PBRP_BRANCH}" \
  -e USE_SECRET_BOOTABLE="${USE_SECRET_BOOTABLE}" -e SECRET_BR="${SECRET_BR}" \
  -e VERSION="${VERSION}" -e VENDOR="${VENDOR}" -e CODENAME="${CODENAME}" \
  -e BUILD_LUNCH="${BUILD_LUNCH}" -e FLAVOR="${FLAVOR}" \
  -e MAINTAINER="${MAINTAINER}" -e CHANGELOG="${CHANGELOG}" \
  -e TEST_BUILD="${TEST_BUILD}" -e PB_OFFICIAL="${PB_OFFICIAL}" \
  -e PB_ENGLISH="${PB_ENGLISH}" -e EXTRA_CMD="${EXTRA_CMD}" \
  -v "${pwd}:/home/builder/:rw,z" \
  -v "/home/builder/.ccache:/srv/ccache:rw,z" \
  --workdir /home/builder/ \
  fr3akyphantom/droid-builder:edge bash \<< EOF
cd /home/builder/
( mkdir -p android || true ) && cd android

# Set GitAuth Infos"
git config --global user.email $GitHubMail
git config --global user.name $GitHubName
git config --global credential.helper store
git config --global color.ui true

if [[ "${CIRCLE_PROJECT_USERNAME}" == "PitchBlackRecoveryProject" ]]; then
# Use Google Git Cookies for Smooth repo-sync
git clone -q "https://$GITHUB_TOKEN@github.com/PitchBlackRecoveryProject/google-git-cookies.git" &> /dev/null
bash google-git-cookies/setup_cookies.sh
rm -rf google-git-cookies
fi

[[ ! -d /tmp ]] && mkdir -p /tmp
# Make a keepalive shell so that it can bypass CI Termination on output freeze
cat << EOF > /tmp/keepalive.sh
#!/bin/bash
echo \$$ > /tmp/keepalive.pid # keep this so that it can be killed from other command
while true; do
  echo "." && sleep 300
done
EOF
chmod a+x /tmp/keepalive.sh

# sync
echo -e "Initializing PBRP repo sync..."
repo init -q -u https://github.com/PitchBlackRecoveryProject/manifest_pb.git -b ${MANIFEST_BRANCH} --depth 1
/tmp/keepalive.sh & repo sync -c -q --force-sync --no-clone-bundle --no-tags -j6 #THREADCOUNT is only 2 in remote docker
kill -s SIGTERM $(cat /tmp/keepalive.pid)

# clean unneeded files
rm -rf development/apps/ development/samples/ packages/apps/

# use pb-10.0
rm -rf vendor/pb && git clone --quiet --progress https://github.com/PitchBlackRecoveryProject/vendor_pb -b pb-10.0 --depth 1 vendor/pb
rm vendor/pb/vendorsetup.sh || true

echo -e "\nGetting the Device Tree on place"
if [[ "${CIRCLE_PROJECT_USERNAME}" == "PitchBlackRecoveryProject" ]]; then
  git clone --quiet --progress https://$GitHubName:$GITHUB_TOKEN@github.com/PitchBlackRecoveryProject/${CIRCLE_PROJECT_REPONAME} -b ${CIRCLE_BRANCH} device/${VENDOR}/${CODENAME}
else
  git clone --quiet --progress https://github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME} -b ${CIRCLE_BRANCH} device/${VENDOR}/${CODENAME}
fi

if [[ -n ${USE_SECRET_BOOTABLE} ]]; then
  if [[ -n ${PBRP_BRANCH} ]]; then
    unset PBRP_BRANCH
  fi
  if [[ -z ${SECRET_BR} ]]; then
    SECRET_BR="android-9.0"
  fi
  rm -rf bootable/recovery
  git clone --quiet --progress https://$GitHubName:$GITHUB_TOKEN@github.com/PitchBlackRecoveryProject/pbrp_recovery_secrets -b ${SECRET_BR} --single-branch bootable/recovery
elif [[ -n ${PBRP_BRANCH} ]]; then
  # FOR EVERYBODY
  rm -rf bootable/recovery
  git clone --quiet --progress https://github.com/PitchBlackRecoveryProject/android_bootable_recovery -b ${PBRP_BRANCH} --single-branch bootable/recovery
fi

if [[ -n $EXTRA_CMD ]]; then
  eval "$EXTRA_CMD"
  cd /home/builder/android/
fi

# See whta's inside
echo -e "\n" && ls -lA .

echo -e "\nPreparing Delicious Lunch..."
export ALLOW_MISSING_DEPENDENCIES=true
source build/envsetup.sh
if [[ -n $BUILD_LUNCH ]]; then
  lunch ${BUILD_LUNCH}
elif [[ -n $FLAVOR ]]; then
  lunch omni_${CODENAME}-${FLAVOR}
fi

# Keep the whole .repo/manifests folder
cp -a .repo/manifests $(pwd)/
rm -rf .repo
mkdir -p .repo && mv manifests .repo/ && ln -s .repo/manifests/default.xml .repo/manifest.xml

/tmp/keepalive.sh & make -j6 recoveryimage
kill -s SIGTERM $(cat /tmp/keepalive.pid)
echo -e "\nYummy Recovery is Served.\n"

echo "Ready to Deploy"
export TEST_BUILDFILE=$(find $(pwd)/out/target/product/${CODENAME}/PitchBlack*-UNOFFICIAL.zip 2>/dev/null)
export BUILDFILE=$(find $(pwd)/out/target/product/${CODENAME}/PitchBlack*-OFFICIAL.zip 2>/dev/null)
export BUILD_FILE_TAR=$(find $(pwd)/out/target/product/${CODENAME}/*.tar 2>/dev/null)
export UPLOAD_PATH=$(pwd)/out/target/product/${CODENAME}/upload/

mkdir ${UPLOAD_PATH}

if [[ -n ${BUILD_FILE_TAR} ]]; then
  echo "Samsung's Odin Tar available: $BUILD_FILE_TAR"
  cp ${BUILD_FILE_TAR} ${UPLOAD_PATH}
fi

if [[ "${CIRCLE_PROJECT_USERNAME}" == "PitchBlackRecoveryProject" ]] && [[ -n $BUILDFILE ]]; then
  echo "Got the Official Build: $BUILDFILE"
  sudo chmod a+x vendor/pb/pb_deploy.sh
  ./vendor/pb/pb_deploy.sh ${CODENAME} ${SFUserName} ${SFPassword} ${GITHUB_TOKEN} ${VERSION} ${MAINTAINER}
  cp $BUILDFILE $UPLOAD_PATH
  export BUILDIMG=$(find $(pwd)/out/target/product/${CODENAME}/recovery.img 2>/dev/null)
  cp $BUILDIMG $UPLOAD_PATH
  ghr -t ${GITHUB_TOKEN} -u ${CIRCLE_PROJECT_USERNAME} -r ${CIRCLE_PROJECT_REPONAME} \
    -n "Latest Release for $(echo $CODENAME)" -b "PBRP $(echo $VERSION)" -c ${CIRCLE_SHA1} -delete \
    ${VERSION} ${UPLOAD_PATH}
elif [[ $TEST_BUILD == 'true' ]] && [[ -n $TEST_BUILDFILE ]]; then
  echo "Got the Unofficial Build: $TEST_BUILDFILE"
  cp $TEST_BUILDFILE $UPLOAD_PATH
  export TEST_BUILDIMG=$(find $(pwd)/out/target/product/${CODENAME}/recovery.img 2>/dev/null)
  cp $TEST_BUILDIMG $UPLOAD_PATH
  ghr -t ${GITHUB_TOKEN} -u ${CIRCLE_PROJECT_USERNAME} -r ${CIRCLE_PROJECT_REPONAME} \
    -n "Test Release for $(echo $CODENAME)" -b "PBRP $(echo $VERSION)" -c ${CIRCLE_SHA1} -delete \
    ${VERSION}-test ${UPLOAD_PATH}
else
  echo -e "Something Wrong with your build system.\nPlease fix it." && exit 1
fi

# SEND NOTIFICATION TO MAINTAINERS, AVAILABLE FOR TEAM DEVS ONLY
if [[ "${CIRCLE_PROJECT_USERNAME}" == "PitchBlackRecoveryProject" ]] && [[ ! -z $TEST_BUILDFILE ]]; then
  echo -e "\nSending the Test build info in Maintainer Group\n"
  TEST_LINK="https://github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/releases/download/${VERSION}-test/$(echo $TEST_BUILDFILE | awk -F'[/]' '{print $NF}')"
  MAINTAINER_MSG="PitchBlack Recovery for \`${VENDOR}\` \`${CODENAME}\` is available Only For Testing Purpose\n\n"
  if [[ ! -z $MAINTAINER ]]; then MAINTAINER_MSG=${MAINTAINER_MSG}"Maintainer: ${MAINTAINER}\n\n"; fi
  if [[ ! -z $CHANGELOG ]]; then MAINTAINER_MSG=${MAINTAINER_MSG}"Changelog:\n"${CHANGELOG}"\n\n"; fi
  MAINTAINER_MSG=${MAINTAINER_MSG}"Go to ${TEST_LINK} to download it."
  if [[ $USE_SECRET_BOOTABLE == 'true' ]]; then
    cd vendor/pb; python3 telegram.py -c "-1001465331122" -M "$MAINTAINER_MSG" -m HTML; cd /home/builder/android/
  else
    cd vendor/pb; python3 telegram.py -c "-1001228903553" -M "$MAINTAINER_MSG" -m HTML; cd /home/builder/android/
  fi
fi

echo -e "\n\nAll Done Gracefully\n\n"
