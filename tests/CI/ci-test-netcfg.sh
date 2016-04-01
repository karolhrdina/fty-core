#!/bin/bash

# Copyright (c) 2014-2016 Eaton
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

# \file    ci-test-netcfg.sh
# \brief   rfc-11 admin/netcfg admin/netcfgs automated test
# \author  Karol Hrdina <KarolHrdina@Eaton.com>
# \version 1.3

# Requirements:
#   Following environment variables are expected to be exported:
#   SUT_HOST
#   SUT_WEB_PORT
# Todos:
#   flock - http://stackoverflow.com/questions/169964/how-to-prevent-a-script-from-running-simultaneously
#   netcfg PUT tests - license issue

# Include our standard routines for CI scripts
. "`dirname $0`"/scriptlib.sh || \
    { echo "FATAL: $0: Could not include script library" >&2; exit 1; }

# Set up weblib test engine
WEBLIB_CURLFAIL_HTTPERRORS_DEFAULT="ignore" # we do this in-script
export WEBLIB_CURLFAIL_HTTPERRORS_DEFAULT
export BASE_URL="${SUT_WEB_SCHEMA}://${SUT_HOST}:${SUT_WEB_PORT}/api/v1"

# Include our standard web routines for CI scripts, also pulls testlib
. "`dirname $0`"/weblib.sh || \
    { echo "FATAL: $0: Could not include web script library" >&2; exit 1; }
[ x"${JSONSH_CLI_DEFINED-}" = xyes ] || CODE=127 die "jsonsh_cli() not defined"

# Setting BUILDSUBDIR and CHECKOUTDIR
NEED_BUILDSUBDIR=no determineDirs_default || true
cd "$BUILDSUBDIR" || die "Unusable BUILDSUBDIR='$BUILDSUBDIR'"
cd "$CHECKOUTDIR" || die "Unusable CHECKOUTDIR='$CHECKOUTDIR'"
logmsg_info "Using BUILDSUBDIR='$BUILDSUBDIR' to run the `basename $0` REST API webserver"

CMPJSON_SH="$CHECKOUTDIR/tests/CI/cmpjson.sh"
[ -x "$CMPJSON_SH" ] || die "Unusable CMPJSON_SH='$CMPJSON_SH'"

PATH="$BUILDSUBDIR/tools:$CHECKOUTDIR/tools:${DESTDIR:-/root}/libexec/bios:/usr/lib/ccache:/sbin:/usr/sbin:/usr/local/sbin:/bin:/usr/bin:/usr/local/bin:$PATH"
export PATH

declare -r REST_NETCFGS="/admin/netcfgs"
declare -r REST_NETCFG="/admin/netcfg"

declare -r IFACES_PATH="/etc/network"
declare -r IFACES_FILE="interfaces"
declare -r IFACES_FILE_INITIAL="${IFACES_FILE}_initial"
declare -r IFACES_FILE_LOOPBACK="${IFACES_FILE_INITIAL}_loopback"

declare -r RESOLV_PATH="/etc"
declare -r RESOLV_FILE="resolv.conf"
declare -r RESOLV_FILE_INITIAL="${RESOLV_FILE}_initial"

declare -r JSON_EXPECTED_FILE="json_expected"
declare -r JSON_RECEIVED_FILE="json_received"

declare -r LOCKFILE="/tmp/ci-test-netcfg.lock"


test_web_port() {
    netstat -tan | grep -w "${SUT_WEB_PORT}" | egrep 'LISTEN' >/dev/null
}
test_web_process() {
    [ -z "$MAKEPID" ] && return 0

    if [ ! -d "/proc/$MAKEPID" ]; then
        logmsg_error "Web-server process seems to have died!" >&2
        # Ensure it is dead though, since we abort the tests now
        kill $MAKEPID >/dev/null 2>&1
        RES_TWP=32
        wait $MAKEPID >/dev/null 2>&1 || RES_TWP=$?
        return $RES_TWP
    fi
    return 0
}
wait_for_web() {
    for a in $(seq 60) ; do
        sleep 5
        test_web_process || exit
        if ( test_web_port ) ; then
            return 0
        fi
    done
    logmsg_error "Port ${SUT_WEB_PORT} still not in LISTEN state" >&2
    return 1
}

# Restore config file to initial state 
# Backup of initial /etc/resolv.conf and /etc/network/interfaces are stored in $TMP_DIR upon start of this test. 
#
# Expects the following variables to be non-empty: TMP_DIR
#
# Arguments
#   $1 - config file name; accepts: "interfaces", "resolv.conf"
# Returns:
#   1 - error
#   0 - success
restore_config() {
    # arguments check
    [[ -z "$TMP_DIR" ]] && return 1
    if [ $# -lt 1 ]; then
        logmsg_error "restore_config(): wrong number of arguments."
        return 1
    fi
    if [[ "$1" != "$IFACES_FILE" && "$1" != "$RESOLV_FILE" ]]; then
        logmsg_error "restore_config(): bad argument '$1'. Valid values: '${IFACES_FILE}', '${RESOLV_FILE}'."
        return 1
    fi

    local __to=
    local __from="${TMP_DIR}"
    case "$1" in
        "$IFACES_FILE")
            __to="${IFACES_PATH}/${IFACES_FILE}"
            __from="${__from}/${IFACES_FILE_INITIAL}"
            ;;
        "$RESOLV_FILE")
            __to="${RESOLV_PATH}/${RESOLV_FILE}"
            __from="${__from}/${RESOLV_FILE_INITIAL}"
            ;;
    esac
    cp -f "${__from}" "${__to}"
    if [[ $? -ne 0 ]]; then
        logmsg_error "restore_config(): Copying '${__from}' to '${__to}' failed."
        return 1
    else
        return 0
    fi
}

TMP_DIR=""
MAKEPID=""
LOCKFILE=""
cleanup() {
    local __exit=$?
    [ -n "$LOCKFILE" ] && rm -f "$LOCKFILE"
    if [[ -n "$TMP_DIR" && -e "$TMP_DIR" ]]; then
        if [ $__exit -ne 0 ]; then
            logmsg_error "Test failed => no cleanup; so it's possible to look at files."
        else
            logmsg_info "Cleaning up '$TMP_DIR'"
            rm -rf "$TMP_DIR"
        fi
    fi
    if [ -n "$MAKEPID" -a -d "/proc/$MAKEPID" ]; then
        logmsg_info "Killing make web-test PID $MAKEPID to exit."
        kill -INT "$MAKEPID"
    fi
    killall -INT tntnet 2>/dev/null
    sleep 1
    killall      tntnet 2>/dev/null
    sleep 1
    ps -ef | grep -v grep | egrep "tntnet" | egrep "^`id -u -n` " && \
        ps -ef | egrep -v "ps|grep" | egrep "$$|make" && \
        logmsg_error "tntnet still alive, trying SIGKILL" && \
        { killall -KILL tntnet 2>/dev/null ;
          [ "${__exit}" = 0 ] && __exit=1; }

    exit_summarizeTestlibResults ${__exit}
}

### Environment preparation ###
# Assumptions:
#   `ci-rc-bios.sh --stop` is called prior to invoking this script
#   script is called as root

# Previous executions should execute successfully first
[ -s "$LOCKFILE" ] && exit 0
init_summarizeTestlibResults "${BUILDSUBDIR}/tests/CI/web/log/`basename "${_SCRIPT_NAME}" .sh`.log"
settraps "cleanup"
touch "$LOCKFILE" && echo "$$" > "$LOCKFILE" || die "Could not initialize LOCKFILE='$LOCKFILE'"

test_web_port && die "Port ${SUT_WEB_PORT} is in LISTEN state when it should be free."

# make sure sasl is running
if ! systemctl is-active saslauthd --quiet; then
    logmsg_info "Starting saslauthd..."
    systemctl start saslauthd || die "Could not start saslauthd."
fi

# check sasl is working
testsaslauthd -u "$BIOS_USER" -p "$BIOS_PASSWD" -s "$SASL_SERVICE" || \
    die "saslauthd is NOT responsive or not configured!"

# make sure database is running
if ! systemctl is-active mysql --quiet; then
    logmsg_info "Starting mysql..."
    systemctl start mysql || die "Could not start mysql."
fi

# do the webserver
LC_ALL=C
LANG=C
export BIOS_USER BIOS_PASSWD SASL_SERVICE LC_ALL LANG

echo "-------- ensure bins to test are up to date -------"
test_it "tested_source_is_configured"
[ -n "${BUILDSUBDIR}" ] && [ -x "${BUILDSUBDIR}/config.status" ] || \
    ./autogen.sh --nodistclean --configure-flags \
    "--prefix=$HOME --with-saslauthd-mux=/var/run/saslauthd/mux" \
    ${AUTOGEN_ACTION_CONFIG}
print_result $? "Could not re-config needed code" || CODE=$? die

test_it "tested_source_is_built"
./autogen.sh ${AUTOGEN_ACTION_MAKE} V=0 web-test-deps
print_result $? "Could not rebuild needed code" || CODE=$? die

./autogen.sh --noparmake ${AUTOGEN_ACTION_MAKE} web-test &
MAKEPID=$!

wait_for_web || die "Web-server is NOT responsive!"
sleep 5
test_web_process || die "test_web_process() failed."
accept_license

### Script starts here ###

# 0. Sanity check: /etc/network/interfaces must exist
[[ -e "${IFACES_PATH}/${IFACES_FILE}" ]] || \
    die "'${IFACES_PATH}/${IFACES_FILE}' does not exist."

# 1. Create temporary dir under /tmp
declare -r TMP_DIR=$(mktemp -d) || \
    die "ERROR: Creating temporary directory failed."
logmsg_info "Temporary directory created successfully: '${TMP_DIR}'."

# 2. Store the initial /etc/resolv.conf
# If /etc/resolv.conf not present it is functionally equivalent to being empty
if [[ ! -e "${RESOLV_PATH}/${RESOLV_FILE}" ]]; then
    touch "${TMP_DIR}/${RESOLV_FILE_INITIAL}"
else
    cp -f "${RESOLV_PATH}/${RESOLV_FILE}" "${TMP_DIR}/${RESOLV_FILE_INITIAL}" || \
        die "copying '${RESOLV_PATH}/${RESOLV_FILE}' to '${TMP_DIR}/${RESOLV_FILE_INITIAL}' failed."
fi
# Remove comments
perl -pi -e 's/^#.*\n$//g' "${TMP_DIR}/${RESOLV_FILE_INITIAL}"

# 3. Store the initial /etc/network/interfaces
cp -f "${IFACES_PATH}/${IFACES_FILE}" "${TMP_DIR}/${IFACES_FILE_INITIAL}" || \
    die "copying '${IFACES_PATH}/${IFACES_FILE}' to '${TMP_DIR}/${IFACES_FILE_INITIAL}' failed."
# Remove comments
perl -pi -e 's/^#.*\n$//g' "${TMP_DIR}/${IFACES_FILE_INITIAL}"

# 3.1 Parse out into array iface names of the initial /etc/network/interfaces
declare -a tmp_arr
declare -a tmp_arr2
while IFS='' read -r line || [[ -n "$line" ]]; do
    if [[ $line =~ ^[[:space:]]*iface[[:space:]]+([[:alnum:]]+)[[:space:]]+ ]]; then
        ifacename="${BASH_REMATCH[1]}"
        if [[ $line =~ loopback ]]; then
            tmp_arr2+=( "${ifacename}" )
        else
            tmp_arr+=( "${ifacename}" )
        fi
    fi
done < "${TMP_DIR}/${IFACES_FILE_INITIAL}"
declare -ar INITIAL_IFACE_NAMES=("${tmp_arr[@]}")
declare -ar LOOPBACK_IFACE_NAMES=("${tmp_arr2[@]}")

logmsg_info "Initial iface names: ${INITIAL_IFACE_NAMES[@]}"
logmsg_info "Loopback iface names: ${LOOPBACK_IFACE_NAMES[@]}"

if [ ${#INITIAL_IFACE_NAMES[@]} -lt 1 ]; then
    die "No interfaces available"
fi

# store a version of initial interfaces file that has only loopback interfaces
cp "${TMP_DIR}/${IFACES_FILE_INITIAL}" "${TMP_DIR}/${IFACES_FILE_LOOPBACK}"
for i in ${INITIAL_IFACE_NAMES[@]}; do
    # remove interface ${i}
    perl -pi -e "s/auto(.+?)${i}(.*?)\n/auto\1\2\n/gs" "${TMP_DIR}/${IFACES_FILE_LOOPBACK}"
    perl -pi -e "s/allow-hotplug(.+?)${i}(.*?)\n/allow-hotplug\1\2\n/gs" "${TMP_DIR}/${IFACES_FILE_LOOPBACK}"
    perl -pi -e "BEGIN{undef $/;} s/iface(\s+)${i}.*?(iface|\Z)/\2/gs" "${TMP_DIR}/${IFACES_FILE_LOOPBACK}"
    perl -pi -e "s/allow-hotplug\s*\n*$//gs" "${TMP_DIR}/${IFACES_FILE_LOOPBACK}"
    perl -pi -e "s/^auto\s*\n*$//gs" "${TMP_DIR}/${IFACES_FILE_LOOPBACK}"
    perl -pi -e "s/^[\s\n]*\Z//gs" "${TMP_DIR}/${IFACES_FILE_LOOPBACK}"
done

# TEST CASES

########################
### Netcfgs_Read_001 ###
########################
TEST_CASE="Netcfgs_Read_001"
printf "=====\t\tTEST_CASE: $TEST_CASE\t\t=====\n"
test_it "$TEST_CASE::netcfgs::0"
tmp='{ "netcfgs": [ '
counter=0
for i in ${INITIAL_IFACE_NAMES[@]}; do
    if [[ $counter -eq 0 ]]; then
        counter=1
        tmp="${tmp} \"${i}\""
        continue
    fi
    tmp="${tmp}, \"${i}\""
done
tmp="${tmp} ] }"
echo "$tmp" | jsonsh_cli -N > "${TMP_DIR}/${JSON_EXPECTED_FILE}"

curlfail_push_expect_200
api_get_json "${REST_NETCFGS}"
print_result $? "'api_get_json ${REST_NETCFGS}' failed"

test_it "$TEST_CASE::cmpjson::0"
echo "$OUT_CURL" > "${TMP_DIR}/${JSON_RECEIVED_FILE}"
"$CMPJSON_SH" -f "${TMP_DIR}/${JSON_EXPECTED_FILE}" "${TMP_DIR}/${JSON_RECEIVED_FILE}"
print_result $? "Test case '$TEST_CASE' failed. Expected and returned json do not match"

logmsg_info "Try repeated requests"
for i in 1 2 3 4 5; do
    test_it "$TEST_CASE::netcfgs::$i"
    api_get_json "${REST_NETCFGS}"
    print_result $? "'api_get_json ${REST_NETCFGS}' failed."

    test_it "$TEST_CASE::cmpjson::$i"
    echo "$OUT_CURL" > "${TMP_DIR}/${JSON_RECEIVED_FILE}"
    "$CMPJSON_SH" -f "${TMP_DIR}/${JSON_EXPECTED_FILE}" "${TMP_DIR}/${JSON_RECEIVED_FILE}"
    print_result $? "Test case '$TEST_CASE'#$i failed. Expected and returned json do not match"
done
curlfail_pop
logmsg_info "Test case '$TEST_CASE' : FINISHED"

########################
### Netcfgs_Read_002 ###
########################
TEST_CASE="Netcfgs_Read_002"
printf "=====\t\tTEST_CASE: $TEST_CASE\t\t=====\n"
logmsg_info "performing test '$TEST_CASE' for ${INITIAL_IFACE_NAMES[O]}"
i=${INITIAL_IFACE_NAMES[0]}
#for i in ${INITIAL_IFACE_NAMES[@]}; do
    # remove interface ${i}
    perl -pi -e "s/auto(.+?)${i}(.*?)\n/auto\1\2\n/gs" "${IFACES_PATH}/${IFACES_FILE}"
    perl -pi -e "s/allow-hotplug(.+?)${i}(.*?)\n/allow-hotplug\1\2\n/gs" "${IFACES_PATH}/${IFACES_FILE}"
    perl -pi -e "BEGIN{undef $/;} s/iface(\s+)${i}.*?(iface|\Z)/\2/gs" "${IFACES_PATH}/${IFACES_FILE}"
    perl -pi -e "s/allow-hotplug\s*\n*$//gs" "${IFACES_PATH}/${IFACES_FILE}"
    perl -pi -e "s/^auto\s*\n*$//gs" "${IFACES_PATH}/${IFACES_FILE}"
    perl -pi -e "s/^[\s\n]*\Z//gs" "${IFACES_PATH}/${IFACES_FILE}"

    # Here we want to use simple_get_json_code because HTTP code should match
    # up with the diff outcome, and this is the most simple approach to use.
    test_it "$TEST_CASE::netcfgs::$i"
    simple_get_json_code "${REST_NETCFGS}" tmp HTTP_CODE
    print_result $? "'api_get_json ${REST_NETCFGS}' failed"

    echo "$tmp" > "${TMP_DIR}/${JSON_RECEIVED_FILE}"
    # File "${TMP_DIR}/${JSON_EXPECTED_FILE}" is present and correctly set from previous 'Netcfgs_Read_001' test execution
    perl -pi -e "s/,\s*\"${i}\"//g" "${TMP_DIR}/${JSON_EXPECTED_FILE}"
    perl -pi -e "s/\"${i}\"\s*,//g" "${TMP_DIR}/${JSON_EXPECTED_FILE}"
    perl -pi -e "s/\[\s*\"${i}\"\s*\]/[]/g" "${TMP_DIR}/${JSON_EXPECTED_FILE}"

    if ! diff -Naru "${IFACES_PATH}/${IFACES_FILE}" "${TMP_DIR}/${IFACES_FILE_LOOPBACK}"; then
        test_it "$TEST_CASE::cmpjson::$i"
        "$CMPJSON_SH" -f "${TMP_DIR}/${JSON_EXPECTED_FILE}" "${TMP_DIR}/${JSON_RECEIVED_FILE}"
        print_result $? "Test case '$TEST_CASE' failed. Expected and returned json do not match"

        test_it "$TEST_CASE::http-code::$i"
        [ $HTTP_CODE -eq 200 ]
        print_result $? "Test case '$TEST_CASE' failed. Expected HTTP return code: 200, received: $HTTP_CODE"
    else
        # if /etc/network/interfaces contains only loopback interface names then 404 expected
        test_it "$TEST_CASE::http-code::$i"
        [ $HTTP_CODE -eq 404 ]
        print_result $? "Test case '$TEST_CASE' failed. Expected HTTP return code: 404, received: $HTTP_CODE"
    fi
#done

test_it "$TEST_CASE::restore_config"
restore_config "$IFACES_FILE"
print_result $? "Restoring '$IFACES_FILE' failed"

# Sanity check
test_it "$TEST_CASE::restore_config::sanity-check"
diff -s "${IFACES_PATH}/${IFACES_FILE}" "${TMP_DIR}/${IFACES_FILE_INITIAL}"
print_result $? "Restore of '${IFACES_PATH}/${IFACES_FILE}' failed"

logmsg_info "Test case '$TEST_CASE' : FINISHED"

########################
### Netcfgs_Read_003 ###
########################
TEST_CASE="Netcfgs_Read_003"

curlfail_push "expect" 'HTTP/[^ ]+ 40[13]'
test_it "$TEST_CASE::netcfgs::forbidden_request"
api_get_json "${REST_NETCFGS}/advdwsqwe234?=345"
print_result $? "'api_get ${REST_NETCFGS}' failed: $OUT_CURL"
curlfail_pop

logmsg_info "Test case '$TEST_CASE' : FINISHED"

#######################
### Netcfg_Read_001 ###
#######################
TEST_CASE="Netcfg_Read_001"
printf "=====\t\tTEST_CASE: $TEST_CASE\t\t=====\n"
read -r -d '' TEMPLATE <<'EOF-TMPL'
{
    "##IFACE##" : {
        "method" : "##METHOD##",
        "nameservers" : [ ##NAMESERVERS##  ]
        ##ADDITIONAL##
    }
}
EOF-TMPL
for i in ${INITIAL_IFACE_NAMES[@]}; do
    tmp="$( cat "${IFACES_PATH}/${IFACES_FILE}" )"
    regex="(iface\s+$i.+?)(iface|\Z)"
    tmp="$(echo "$tmp" | perl -lne 'BEGIN{undef $/;} m/'"$regex"'/gs; print $1')"

    method="$( echo "$tmp" | perl -lne 'BEGIN{undef $/;} m/iface\s+\S+\s+\S+\s+(\S+)/gs; print $1' )"
    address="$( echo "$tmp" | perl -lne 'BEGIN{undef $/;} m/\baddress\s+(\S+)/gs; print $1' )"
    netmask="$( echo "$tmp" | perl -lne 'BEGIN{undef $/;} m/netmask\s+(\S+)/gs; print $1' )"
    gateway="$( echo "$tmp" | perl -lne 'BEGIN{undef $/;} m/gateway\s+(\S+)/gs; print $1' )"

    additional=
    [ -n "$address" ] && additional="${additional}, \"address\" : \"$address\""
    [ -n "$netmask" ] && additional="${additional}, \"netmask\" : \"$netmask\""
    [ -n "$gateway" ] && additional="${additional}, \"gateway\" : \"$gateway\""

    nameservers=
    while IFS='' read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^nameserver[[:space:]]+(.+)$ ]]; then
            if [[ -z "$nameservers" ]]; then
                nameservers="\"${BASH_REMATCH[1]}\""
            else
                nameservers="${nameservers}, \"${BASH_REMATCH[1]}\""
            fi
        fi
    done < "${TMP_DIR}/${RESOLV_FILE_INITIAL}"

    template="$TEMPLATE"
    template="${template/\#\#IFACE\#\#/$i}"
    template="${template/\#\#METHOD\#\#/$method}"
    template="${template/\#\#NAMESERVERS\#\#/$nameservers}"
    template="${template/\#\#ADDITIONAL\#\#/$additional}"
    echo "$template" | jsonsh_cli -N > "${TMP_DIR}/${JSON_EXPECTED_FILE}"

    curlfail_push_expect_200
    test_it "$TEST_CASE::netcfg::$i"
    api_get_json "${REST_NETCFG}/${i}"
    print_result $? "'api_get_json ${REST_NETCFG}/${i}' failed"
    curlfail_pop

    test_it "$TEST_CASE::cmpjson::$i"
    echo "$OUT_CURL" > "${TMP_DIR}/${JSON_RECEIVED_FILE}"
    "$CMPJSON_SH" -f "${TMP_DIR}/${JSON_EXPECTED_FILE}" "${TMP_DIR}/${JSON_RECEIVED_FILE}"
    print_result $? "Test case '$TEST_CASE' failed. Expected and returned json do not match"
done

logmsg_info "Test case '$TEST_CASE' : FINISHED"

#######################
### Netcfg_Read_002 ###
#######################
TEST_CASE="Netcfg_Read_002"
printf "=====\t\tTEST_CASE: $TEST_CASE\t\t=====\n"
i=0

bad_name=$(mktemp -u XXXX)
bad_name="${bad_name}1"

logmsg_info "Request non-existing interface"
# Implementation returns 404 or 400 depending on the iface name
curlfail_push "expect" 'HTTP/[^ ]+ 40[04]'

i=$(($i+1))
test_it "$TEST_CASE::netcfg::$i"
api_get_json "${REST_NETCFG}/${bad_name}"
print_result $? "'api_get_json ${REST_NETCFG}/${bad_name}' failed"

logmsg_info 'api/v1/admin/netcfg/<non_existing_interface>?<junk>'
i=$(($i+1))
test_it "$TEST_CASE::netcfg::$i"
api_get_json "${REST_NETCFG}/${bad_name}?gnsfd=f23sfd+sf4fw4=\?"
print_result $? "'api_get_json ${REST_NETCFG}/${bad_name}?gnsfd=f23sfd+sf4fw4=\?' failed"

# TODO: Remove any existing interface and the request it.
curlfail_pop

logmsg_info 'api/v1/admin/netcfg/<junk_here>'

#curlfail_push_expect_400
curlfail_push "expect" 'HTTP/[^ ]+ 40[04]'
i=$(($i+1))
test_it "$TEST_CASE::netcfg::$i"
api_get_json "${REST_NETCFG}/fas40+_245625%20_=345"
print_result $? "'api_get_json ${REST_NETCFG}/fas40+_245625%20_=345' failed"
curlfail_pop

#curlfail_push_expect_400
curlfail_push "expect" 'HTTP/[^ ]+ 40[04]'
i=$(($i+1))
test_it "$TEST_CASE::netcfg::$i"
api_get_json "${REST_NETCFG}/40245625%20345f4f34"
print_result $? "'api_get_json ${REST_NETCFG}/40245625%20345f4f34' failed"
curlfail_pop

#curlfail_push_expect_400
curlfail_push "expect" 'HTTP/[^ ]+ 40[04]'
i=$(($i+1))
test_it "$TEST_CASE::netcfg::$i"
api_get_json "${REST_NETCFG}/asdf%2520%2Bsdf+%25"
print_result $? "'api_get_json ${REST_NETCFG}/asdf%2520%2Bsdf+%25' failed"
curlfail_pop

# NOTE: This unescaped space may seem like separator for invalid HTTP verb
#curlfail_push_expect_400
curlfail_push "expect" 'HTTP/[^ ]+ 40[04]'
i=$(($i+1))
test_it "$TEST_CASE::netcfg::$i"
api_get "${REST_NETCFG}/eth\ 0\/asdf%2520%2Bsdf+%25"
print_result $? "'api_get ${REST_NETCFG}/eth\ 0\/asdf%2520%2Bsdf+%25' failed"
curlfail_pop


logmsg_info 'api/v1/admin/netcfg/<existing_interface>?<junk>'
curlfail_push_expect_200
last_name="${INITIAL_IFACE_NAMES[-1]}"

i=$(($i+1))
test_it "$TEST_CASE::netcfg::$i::$last_name"
api_get_json "${REST_NETCFG}/${last_name}?asdf%2520%2Bsdf+%25=20'"
print_result $? "'api_get_json ${REST_NETCFG}/${last_name}?asdf%2520%2Bsdf+%25=20' failed"

i=$(($i+1))
test_it "$TEST_CASE::netcfg::$i::$last_name"
api_get_json "${REST_NETCFG}/${last_name}?asdf%2520%2Bsdf+%25=20+ \ "
print_result $? "'api_get_json ${REST_NETCFG}/${last_name}?asdf%2520%2Bsdf+%25=20+ \ ' failed"

i=$(($i+1))
test_it "$TEST_CASE::netcfg::$i::$last_name"
api_get_json "${REST_NETCFG}/${last_name}?asdf%2520%2Bsdf\ \++%25i \ " tmp HTTP_CODE
print_result $? "'api_get_json ${REST_NETCFG}/${last_name}?asdf%2520%2Bsdf\ \++%25i \ ' failed"
curlfail_pop

logmsg_info "Test case '$TEST_CASE' : FINISHED"

#########################
### Netcfg_Update_001 ###
#########################
# This and the other PUT test are currently ommited due to implementation issues and possible licensing conflict
# TODO revert back
