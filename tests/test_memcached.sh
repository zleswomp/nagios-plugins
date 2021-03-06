#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2015-05-25 01:38:24 +0100 (Mon, 25 May 2015)
#
#  https://github.com/harisekhon/nagios-plugins
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback to help improve or steer this or other code I publish
#
#  https://www.linkedin.com/in/harisekhon
#

set -eu
[ -n "${DEBUG:-}" ] && set -x
srcdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$srcdir/..";

. ./tests/utils.sh

echo "
# ============================================================================ #
#                               M e m c a c h e d
# ============================================================================ #
"

MEMCACHED_HOST="${DOCKER_HOST:-${MEMCACHED_HOST:-${HOST:-localhost}}}"
MEMCACHED_HOST="${MEMCACHED_HOST##*/}"
MEMCACHED_HOST="${MEMCACHED_HOST%%:*}"
export MEMCACHED_HOST

export MEMCACHED_PORT=11211

export DOCKER_IMAGE="memcached"
export DOCKER_CONTAINER="nagios-plugins-memcached-test"

startupwait=1

echo "Setting up Memcached test container"
launch_container "$DOCKER_IMAGE" "$DOCKER_CONTAINER" $MEMCACHED_PORT

echo "creating test Memcached key-value"
echo -ne "add myKey 0 100 4\r\nhari\r\n" | nc $MEMCACHED_HOST $MEMCACHED_PORT
echo done
hr
# MEMCACHED_HOST obtained via .travis.yml
$perl -T $I_lib ./check_memcached_write.pl -v
hr
$perl -T $I_lib ./check_memcached_key.pl -k myKey -e hari -v
hr
$perl -T $I_lib ./check_memcached_stats.pl -w 15 -c 20 -v
hr
delete_container
