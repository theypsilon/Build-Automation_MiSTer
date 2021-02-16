#!/usr/bin/env bash
set -euo pipefail

DISPATCH_URL="https://api.github.com/repos/MiSTer-unstable-nightlies/Build-Automation_MiSTer/dispatches"
ARCHIVE_URL="https://github.com/MiSTer-unstable-nightlies/Build-Automation_MiSTer/archive/main.zip"

echo
echo "Unpacking ${ARCHIVE_URL}"
BUILD_AUTOMATION_DIR_TMP=$(mktemp -d)
wget -q -O "${BUILD_AUTOMATION_DIR_TMP}/tmp.zip" "${ARCHIVE_URL}"

unzip -q "${BUILD_AUTOMATION_DIR_TMP}/tmp.zip" -d "${BUILD_AUTOMATION_DIR_TMP}"

cp "${BUILD_AUTOMATION_DIR_TMP}/Build-Automation_MiSTer-main/templates/Dockerfile" .
cp "${BUILD_AUTOMATION_DIR_TMP}/Build-Automation_MiSTer-main/templates/Dockerfile.file-filter" .
cp "${BUILD_AUTOMATION_DIR_TMP}/Build-Automation_MiSTer-main/templates/.dockerignore" .

rm -rf "${BUILD_AUTOMATION_DIR_TMP}"

echo ""
echo "Arguments"
REPOSITORY_DOMAIN="${REPOSITORY%%/*}"
REPOSITORY_NAME="${REPOSITORY##*/}"
echo "REPOSITORY_DOMAIN: ${REPOSITORY_DOMAIN}"
echo "REPOSITORY_NAME: ${REPOSITORY_NAME}"

if [[ "${RELEASE_TAG:-}" == "" ]] ; then
    RELEASE_TAG="unstable-builds"
fi
echo "RELEASE_TAG: ${RELEASE_TAG}"

if [[ "${CORE_NAME:-}" == "" ]] ; then
    CORE_NAME="${REPOSITORY_NAME%%_MiSTer}"
fi
echo "CORE_NAME: ${CORE_NAME}"

if [[ "${DOCKER_IMAGE:-}" == "" ]] ; then
    DOCKER_IMAGE="theypsilon/quartus-lite-c5:17.0.2.docker0"
fi
echo "DOCKER_IMAGE: ${DOCKER_IMAGE}"

if [[ "${COMPILATION_COMMAND:-}" == "" ]] ; then
    COMPILATION_COMMAND="/opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile ${CORE_NAME}.qpf"
fi
echo "COMPILATION_COMMAND: ${COMPILATION_COMMAND}"

if [[ "${COMPILATION_OUTPUT:-}" == "" ]] ; then
    COMPILATION_OUTPUT="output_files/${CORE_NAME}.rbf"
fi
echo "COMPILATION_OUTPUT: ${COMPILATION_OUTPUT}"

FILE_EXTENSION="${COMPILATION_OUTPUT##*.}"
RELEASE_FILE="${CORE_NAME}_unstable_$(date +%Y%m%d)_${GITHUB_SHA:0:4}"
if [[ "${FILE_EXTENSION}" != "${COMPILATION_OUTPUT}" ]] ; then
    RELEASE_FILE="${RELEASE_FILE}.${FILE_EXTENSION}"
fi

echo
echo "Fetching previous build for comparing..."
LATEST_BUILD_ZIP="LatestBuild.zip"
export GITHUB_TOKEN="${GITHUB_TOKEN}"
if gh release download "${RELEASE_TAG}" --pattern "${LATEST_BUILD_ZIP}" 2> /dev/null ; then
    PREVIOUS_BUILD_DIR_TMP=$(mktemp -d)
    unzip -q "${LATEST_BUILD_ZIP}" -d "${PREVIOUS_BUILD_DIR_TMP}"
    rm "${LATEST_BUILD_ZIP}"
    echo "Done."
else
    echo "No previous build found."
    FIRST_TIME="true"
fi

echo
echo "Grabbing files for build environment..."
git submodule update --init --recursive

CURRENT_BUILD_FOLDER_TMP=$(mktemp -d)
docker build -f Dockerfile.file-filter -t filtered_files .
docker cp $(docker create --rm filtered_files):/files "${CURRENT_BUILD_FOLDER_TMP}/"
CURRENT_BUILD_DIR="${CURRENT_BUILD_FOLDER_TMP}/files"

DIFFERENCES_FOUND="true"
if [[ "${PREVIOUS_BUILD_DIR_TMP:-}" != "" ]] ; then

    DIFFERENCES_FOUND="false"
    CURRENT_BUILD_FILES_TMP=$(mktemp)
    PREVIOUS_BUILD_FILES_TMP=$(mktemp)

    pushd "${CURRENT_BUILD_DIR}" > /dev/null
    find . > "${CURRENT_BUILD_FILES_TMP}"
    popd > /dev/null
    pushd "${PREVIOUS_BUILD_DIR_TMP}" > /dev/null
    find . > "${PREVIOUS_BUILD_FILES_TMP}"
    popd > /dev/null

    CURRENT_BUILD_QTY=$(cat "${CURRENT_BUILD_FILES_TMP}" | wc -l | awk '{print $1}')
    PREVIOUS_BUILD_QTY=$(cat "${PREVIOUS_BUILD_FILES_TMP}" | wc -l | awk '{print $1}')

    if ! git diff --exit-code "${PREVIOUS_BUILD_FILES_TMP}" "${CURRENT_BUILD_FILES_TMP}" ; then
        DIFFERENCES_FOUND="true"

        echo
        echo "Found differences"
        echo "Current build #files: ${CURRENT_BUILD_QTY}"
        echo "Previous build #files: ${PREVIOUS_BUILD_QTY}"
    else
        CHANGED_FILES=()
        while IFS="" read -r line || [ -n "${line}" ]
        do
            LINE_PATH_1="${PREVIOUS_BUILD_DIR_TMP}/${line}"
            LINE_PATH_2="${CURRENT_BUILD_DIR}/${line}"

            if [ ! -f "${LINE_PATH_1}" ] && [ ! -f "${LINE_PATH_2}" ] ; then continue ; fi
            if [ ! -f "${LINE_PATH_2}" ] ; then echo "UNEXPEXTED: File ${LINE_PATH_2} doesn't exist!" ; exit 1 ; fi
            if [ ! -f "${LINE_PATH_1}" ] ; then echo "UNEXPEXTED: File ${LINE_PATH_1} doesn't exist!" ; exit 1 ; fi

            if ! git diff --exit-code --ignore-space-at-eol "${LINE_PATH_1}" "${LINE_PATH_2}" ; then
                echo
                echo "Found differences"
                echo
                CHANGED_FILES+=( "${line}" )
            fi
        done < "${CURRENT_BUILD_FILES_TMP}"

        if [ ${#CHANGED_FILES[@]} -ge 1 ] ; then
            DIFFERENCES_FOUND="true"
            echo "Following files have changes: "
            for changed_file in "${CHANGED_FILES[@]}"
            do
                echo "${changed_file}"
            done
        fi
    fi

    rm -rf "${CURRENT_BUILD_FILES_TMP}"
    rm -rf "${PREVIOUS_BUILD_FILES_TMP}"
    rm -rf "${PREVIOUS_BUILD_DIR_TMP}"
fi

if [[ "${DIFFERENCES_FOUND}" != "true" ]] ; then
    rm -rf "${CURRENT_BUILD_FOLDER_TMP}"
    echo
    echo "No changes detected since latest build."
    echo "Skipping..."
    exit 0
fi

echo
echo "Creating release ${RELEASE_FILE}."

pushd "${CURRENT_BUILD_DIR}" > /dev/null
zip -q -9 -r "${LATEST_BUILD_ZIP}" .
popd > /dev/null

sed -i "s%<<DOCKER_IMAGE>>%${DOCKER_IMAGE}%g" Dockerfile
sed -i "s%<<COMPILATION_COMMAND>>%${COMPILATION_COMMAND}%g" Dockerfile
sed -i "s%<<COMPILATION_OUTPUT>>%${COMPILATION_OUTPUT}%g" Dockerfile

docker build -t artifact .
docker run --rm artifact > "${RELEASE_FILE}"

RELEASE_FILE_URL="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}/${RELEASE_FILE}"
echo "Uploading release to ${RELEASE_FILE_URL}"

if ! gh release list | grep -q "${RELEASE_TAG}" ; then
    gh release create "${RELEASE_TAG}" -p || true
    sleep 15s
fi

if gh release view "${RELEASE_TAG}" | grep -q "${RELEASE_FILE}" ; then
    echo
    echo "Release already uploaded."
    exit 0
fi

echo "${GITHUB_SHA}" > commit.txt

gh release upload "${RELEASE_TAG}" "${RELEASE_FILE}" --clobber
gh release upload "${RELEASE_TAG}" "${CURRENT_BUILD_DIR}/${LATEST_BUILD_ZIP}" --clobber
gh release upload "${RELEASE_TAG}" commit.txt --clobber

rm -rf "${CURRENT_BUILD_FOLDER_TMP}"

if [[ "${FIRST_TIME:-false}" == "true" ]] ; then
    exit 0
fi

COMMIT_MESSAGE="$(git log --pretty='format:%as %h: %s [%an]' -n1)"

WEBHOOK_REQUEST_SENT="false"
if [[ "${WEBHOOK_URL:-}" != "" ]] ; then
    DISCORD_MESSAGE="Latest **${CORE_NAME}** unstable build: ${RELEASE_FILE_URL}"
    DISCORD_MESSAGE+="\n"
    DISCORD_MESSAGE+="\`\`\`Commit ${COMMIT_MESSAGE}\`\`\`"

    echo
    echo "Discord message:"
    echo "${DISCORD_MESSAGE}"
    echo

    curl --fail --output /dev/null \
        -i \
        -H "Accept: application/json" \
        -H "Content-Type:application/json" \
        -X POST \
        --data "{\"content\": \"${DISCORD_MESSAGE}\"}" \
        "${WEBHOOK_URL}"
        
    echo "Message sent successfully."
    WEBHOOK_REQUEST_SENT="true"
fi

if [[ "${DISPATCH_TOKEN:-}" != "" ]] ; then
    CLIENT_PAYLOAD="\"release_file_url\":\"${RELEASE_FILE_URL}\""
    CLIENT_PAYLOAD+=",\"core_name\":\"${CORE_NAME}\""
    CLIENT_PAYLOAD+=",\"repository\":\"${REPOSITORY}\""
    CLIENT_PAYLOAD+=",\"release_tag\":\"${RELEASE_TAG}\""
    CLIENT_PAYLOAD+=",\"commit_sha\":\"${GITHUB_SHA}\""
    CLIENT_PAYLOAD+=",\"commit_msg\":\"${COMMIT_MESSAGE}\""
    CLIENT_PAYLOAD+=",\"webhook_request_sent\":\"${WEBHOOK_REQUEST_SENT}\""

    DATA_JSON="{\"event_type\":\"notify_release\",\"client_payload\":{${CLIENT_PAYLOAD}}}"
    
    echo
    echo "Sending dispatch event to ${DISPATCH_URL} with payload:"
    echo "${DATA_JSON}"
    echo

    curl --fail --output /dev/null \
        -X POST \
        -H "Authorization: token ${DISPATCH_TOKEN}" \
        -H "Accept: application/vnd.github.everest-preview+json" \
        -H "Content-Type: application/json" \
        --data "${DATA_JSON}" \
        "${DISPATCH_URL}"
        
    echo "Event sent succesfully."
fi
