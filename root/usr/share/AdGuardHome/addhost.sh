#!/bin/sh

checkmd5(){
local nowmd5=$(md5sum /etc/hosts)
nowmd5=${nowmd5%% *}
local lastmd5=$(uci get AdGuardHome.AdGuardHome.hostsmd5 2>/dev/null)
if [ "$nowmd5" != "$lastmd5" ]; then
	uci set AdGuardHome.AdGuardHome.hostsmd5="$nowmd5"
	uci commit AdGuardHome
	[ "$1" == "noreload" ] || /etc/init.d/AdGuardHome reload
fi
}

[ "$1" == "del" ] && sed -i '/programaddstart/,/programaddend/d' /etc/hosts && checkmd5 "$2" && exit 0

/usr/bin/awk 'BEGIN{
while ((getline < "/tmp/dhcp.leases") > 0)
{
    a[$2]=$4;
}
while (("ip -6 neigh show | grep -v fe80" | getline) > 0)
{
    if (a[$5] && a[$5] != "*") print $1" "a[$5];
}
}' | sort -u > /tmp/tmphost

if grep -q "^#programaddstart$" /etc/hosts && grep -q "^#programaddend$" /etc/hosts; then
	awk '/^#programaddstart$/{inb=1;next} /^#programaddend$/{inb=0;next} inb' /etc/hosts > /tmp/tmphostold
	if cmp -s /tmp/tmphostold /tmp/tmphost; then
		rm -f /tmp/tmphost /tmp/tmphostold
		checkmd5 "$2"
		exit 0
	fi
fi

/usr/bin/awk -v nb="/tmp/tmphost" '
BEGIN{
while ((getline l < nb) > 0)
{
    block = block l "\n";
}
}
/^#programaddstart$/ {print; printf "%s", block; skip=1; found=1; next}
skip && /^#programaddend$/ {print; skip=0; next}
skip {next}
{print}
END{
if (!found)
{
    print "#programaddstart";
    printf "%s", block;
    print "#programaddend";
} else if (skip) {
    print "#programaddend";
}}' /etc/hosts > /tmp/hostsnew
cat /tmp/hostsnew > /etc/hosts
rm -f /tmp/tmphost /tmp/tmphostold /tmp/hostsnew
checkmd5 "$2"
