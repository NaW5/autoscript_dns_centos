#!/bin/bash
# Kiểm tra cấu hình mạng
interface=$(ip -o -f inet addr show | awk '{print $2}' | grep -E '^(eth|ens|wlan|enp)' | head -n 1)
if [ -z "$interface" ]; then
	echo "Không tìm thấy network interface. Vui lòng cài đặt lại cấu hình mạng."
	exit 1
fi
# if ! rpm -q bind bind-utils > /dev/null 2>&1; then
# 	echo "Gói bind chưa cài đặt, cài đặt gói bind..."
# 	sed -i -e "/^mirrorlist/d;/^#baseurl=/{s,^#,,;s,/mirror,/vault,;}" /etc/yum.repos.d/CentOS*.repo
# 	yum update -y && yum install bind bind-utils -y
	
# 	while [ ! -f /etc/named.conf ]; do
# 		sleep 1
# 		echo "Đợi gói bind khởi tạo file..."
# 	done
# 	clear
# elif ! yum check-update bind bind-utils > /dev/null 2>&1; then
# 	echo "Gói bind chưa được cập nhật. Cập nhật gói bind..."
# 	yum update -y
# fi
# Lưu các file cần tùy chỉnh
ifcfg="/etc/sysconfig/network-scripts/ifcfg-${interface}"
named="/etc/named.conf"
namedrfc="/etc/named.rfc1912.zones"
chmod 644 "$named"
chmod 644 "$namedrfc"
# Backup file.
cp "$ifcfg" "${ifcfg}.bak"
cp "$named" "${named}.bak"
cp "$namedrfc" "${namedrfc}.bak"
trap cleanup SIGINT
# Tắt firewall
firewall-cmd --permanent --zone=public --add-service=dns > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1

# Phục hồi nếu script lỗi hoặc interupt
cleanup() 
{

	if [[ -f "${ifcfg}.bak" && -f "${named}.bak" && -f "${namedrfc}.bak" ]]; then
		mv "${ifcfg}.bak" "$ifcfg"
		mv "${named}.bak" "$named"
		mv "${namedrfc}.bak" "$namedrfc"
	fi
	systemctl restart network
	systemctl restart named
	exit
}

prompt() 
{
	while true; do
		echo "Chọn loại muốn cấu hình:"
		echo "1. Cấu hình IP."
		echo "2. Cấu hình Domain."
		echo "3. Cấu hình Backup DNS."
		echo "4. Cấu hình forward DNS."
		echo "0. Thoát"
		read -p "Lựa chọn: " choice
		case "$choice" in
			1)
				while true; do
					echo "Chọn chế độ muốn cấu hình: "
					echo "1. Tĩnh."
					echo "2. Động."
					read -p "Lựa chọn: " choice
					if [[ "$choice" == 1 ]]; then
						ip_setup 1
						break
					elif [[ "$choice" == 2 ]]; then
						ip_setup
						break
					else 
						echo "Lựa chọn không hợp lệ. Vui lòng thử lại."
					fi
				done
				;;
			2)
				zone_setup 1
				;;
			3)
				while true; do
					echo "Chọn loại server muốn cấu hình:"
					echo "1. Primary"
					echo "2. Backup"
					read -p "Lựa chọn: " choice
					if [[ "$choice" == 1 ]]; then
						backup_setup 2
						break
					elif [[ "$choice" == 2 ]]; then
						backup_setup 3
						break
					else
						echo "Lựa chọn không hợp lệ. Vui lòng thử lại."
					fi
				done
				;;
			4)
				forwarder_setup
				systemctl restart named
				;;
			0)
				exit 0
				;;
			*)
				echo "Lựa chọn không hợp lệ. Vui lòng thử lại."
				;;
		esac
	done
}

ip_setup() 
{
	local mode="$1"
	if [[ "$mode" == 1 ]]; then
		while true; do
			read -p "Nhập địa chỉ IP/DNS cho hệ thống: " ipaddr
			if ! ip_check "$ipaddr"; then
				echo "IP không hợp lệ. Vui lòng thử lại."
			else
				break
			fi
		done
		prefix=$(ip_to_prefix_length "$ipaddr")

		sed -i -e "s/^BOOTPROTO=.*$/BOOTPROTO=none/" \
				  -e "/^DNS1\|^IPADDR\|^GATEWAY\|^PREFIX/d" "$ifcfg"
		{
			echo "DNS1=${ipaddr}"
			echo "IPADDR=${ipaddr}"
			echo "PREFIX=${prefix}"
			echo "GATEWAY=${ipaddr}"
		} >> "$ifcfg"
		
		if ! grep -q "listen-on .*${ipaddr};" "$named"; then
			sed -i -e "/listen-on .*127\.0\.0\.1;/s|;|; ${ipaddr};| " "$named"
		fi
		if ! grep -q "#listen-on-v6" "$named"; then
			sed -i -e "s/listen-on-v6/#listen-on-v6/" "$named"
		fi
		if ! grep -q "allow-query.*any;" "$named"; then
			sed -i -e "/allow-query.*localhost;/s|;|; any;|" "$named"
		fi
	else
		sed -i -e "s/^BOOTPROTO=.*$/BOOTPROTO=dhcp/" \
				  -e "/^DNS1\|^IPADDR\|^GATEWAY\|^PREFIX/d" "$ifcfg"
	fi
	#Khởi động lại dịch vụ network
	systemctl restart network
	systemctl start named > /dev/null 2>&1
	systemctl restart named > /dev/null 2>&1
}
fw_zone() {
	local mode="$1"
	echo "Khai báo zone thuận"
	read -p "Nhập tên miền cần quản lý: " fw_dom
	if grep -q "${fw_dom}" "$namedrfc"; then
		echo "Zone ${fw_dom} đã tồn tại."
		return
	fi
	fw_rec="forward.${fw_dom}"
	if [[ "$mode" != 3 ]]; then
		while true; do
			read -p "Nhập địa chỉ cho ${fw_dom} : " zone_ip
			if ! ip_check "$zone_ip"; then
				echo "IP không hợp lệ. Vui lòng thử lại."
			else
				break
			fi
		done
	else
		zone_ip="$ipaddr"
	fi
	zone_prefix=$(ip_to_prefix_length "$zone_ip")
	{
		echo "zone \"${fw_dom}\"	IN	{"
		echo "		type master;"
		echo "		file \"${fw_rec}\";"
		echo "		allow-update { none; };"
		echo "};"
		echo ""
	} >> "$namedrfc"
	
	# Tạo record forward
	if [[ "$mode" != 3 ]]; then
		name_server="server"
		admin_server="root"
		
		{
			echo "\$TTL 86400"
			echo "@	IN	SOA		${name_server}.${fw_dom}. ${admin_server}.${fw_dom}. ("
			echo "	2018210901		;Serial"
			echo "	3600		;Refresh"
			echo "	1800		;Retry"
			echo "	604800		;Expire"
			echo "	86400		;Minimum TTL"
			echo ")"
			echo "@	IN	NS		${name_server}.${fw_dom}."
			echo "@	IN	A		${zone_ip}"
			echo "${name_server}	IN	A		${zone_ip}"
			echo ""
		} >> "/var/named/${fw_rec}"
	fi
	
	local -a octets
	IFS='.' read -r -a octets <<< "$zone_ip"
	local reverse_zone
	
	if [[ "$zone_prefix" -le 8 ]]; then
		reverse_zone="${octets[0]}.in-addr.arpa"
	elif [[ "$zone_prefix" -le 16 ]]; then
		reverse_zone="${octets[1]}.${octets[0]}.in-addr.arpa"
	elif [[ "$zone_prefix" -le 24 ]]; then
		reverse_zone="${octets[2]}.${octets[1]}.${octets[0]}.in-addr.arpa"
	else
		reverse_zone="${octets[3]}.${octets[2]}.${octets[1]}.${octets[0]}.in-addr.arpa"
	fi
	
	rev_zone "$mode" "$fw_dom" "$reverse_zone" "$zone_prefix" "$zone_ip" "$name_server" "$admin_server"
	
	systemctl start named > /dev/null 2>&1
	systemctl restart named > /dev/null 2>&1
}

rev_zone() {
	local mode="$1"
	local fw_dom="$2"
	local re_zone="$3"
	local zone_prefix="$4"
	local zone_ip="$5"
	local name_server="$6"
	local admin_server="$7"
	local backup_exclusive="$8"
		
	re_rec="rev.$(ipcalc -n "${zone_ip}/${zone_prefix}" | awk -F'=' '{print $2}')"
	if ! grep -qE "zone[[:space:]]*\"${re_zone}\"" "$namedrfc"; then
		{
			echo "zone \"${re_zone}\"	IN	{"
			echo "		type master;"
			echo "		file \"${re_rec}\";"
			echo "		allow-update { none; };"
			echo "};"
			echo ""
		} >> "$namedrfc"
	fi
	
	# Tạo record reverse 
	if [[ "$mode" != 3 ]]; then
		{
			if ! grep -q "^\$TTL" "/var/named/${re_rec}" > /dev/null 2>&1; then
				echo "\$TTL 86400"
				echo "@	IN	SOA		${name_server}.${fw_dom}. ${admin_server}.${fw_dom}. ("
				echo "		$(date +%Y%m%d)01		;Serial"
				echo "		3600		;Refresh"
				echo "		1800		;Retry"
				echo "		604800		;Expire"
				echo "		86400		;Minimum TTL"
				echo ")"
			fi
			if [[ -z "$backup_exclusive" ]]; then

				echo "@	IN	NS		${name_server}.${fw_dom}."
				local -a octets
				IFS='.' read -r -a octets <<< "${zone_ip}"
				
				if [[ "$zone_prefix" -eq 24 ]]; then
					
					echo "${octets[3]}	IN	PTR		${name_server}.${fw_dom}."
					echo "${octets[3]}	IN	PTR		${fw_dom}."
				elif [[ "$zone_prefix" -eq 16 ]]; then
					
					echo "${octets[3]}.${octets[2]}	IN	PTR		${name_server}.${fw_dom}."
					echo "${octets[3]}.${octets[2]}	IN	PTR		${fw_dom}."
				elif [[ "$zone_prefix" -eq 8 ]]; then
					
					echo "${octets[3]}.${octets[2]}.${octets[1]}	IN	PTR		${name_server}.${fw_dom}."
					echo "${octets[3]}.${octets[2]}.${octets[1]}	IN	PTR		${fw_dom}."
				fi
			fi
		} >> "/var/named/${re_rec}"
	fi
}

zone_setup() 
{
	local type="$1"
	if [[ "$type" == 3 ]]; then
		echo "Nhập các zone tương ứng với primary server."
	fi
	while true; do
		fw_zone "$type"
		read -p "Tiếp tục khai báo zone ? (y/n): " choice
		if [[ "$choice" != "y" ]]; then
			break
		fi
	done
}

backup_setup()
{
	local type="$1"
	if ! grep -q "BOOTPROTO=none" "$ifcfg"; then
		echo "Cấu hình IP tĩnh."
		ip_setup 1
	fi
	
	while true; do
		if [[ "$type" == 2 ]]; then
			read -p "Nhập địa chỉ máy chủ backup: " trans_ip
		elif [[ "$type" == 3 ]]; then
			read -p "Nhập địa chỉ máy chủ primary: " trans_ip
			if [ ! -f ~/.ssh/id_rsa ]; then
		    	ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -q -N "" > /dev/null 2>&1
			fi
			ssh-copy-id root@"$trans_ip" > /dev/null 2>&1
			scp root@"$trans_ip":/etc/named.rfc1912.zones /etc/ > /dev/null 2>&1
		fi

		if ! ip_check "$trans_ip"; then
			echo "IP không hợp lệ. Vui lòng thử lại."
		else
			break
		fi
	done
	
	zones=$(get_zones)

	if [[ "$type" == 2 ]]; then
		local backup_prefix=$(ip_to_prefix_length "$trans_ip")
		local -a octets
		IFS='.' read -r -a octets <<< "$trans_ip"
		local reverse_backup

		if [[ "$backup_prefix" -le 8 ]]; then
			reverse_backup="${octets[0]}.in-addr.arpa"
		elif [[ "$backup_prefix" -le 16 ]]; then
			reverse_backup="${octets[1]}.${octets[0]}.in-addr.arpa"
		elif [[ "$backup_prefix" -le 24 ]]; then
			reverse_backup="${octets[2]}.${octets[1]}.${octets[0]}.in-addr.arpa"
		else
			reverse_backup="${octets[3]}.${octets[2]}.${octets[1]}.${octets[0]}.in-addr.arpa"
		fi
		
		local primary_holder=(echo ${numbers[1]})
		rev_zone "2" "$primary_holder" "$reverse_backup" "$backup_prefix" "$trans_ip" "backup" "admin_backup" "0"
	fi
	
	
	if grep -q 'allow-transfer' "$named"; then
		if ! grep -q "allow-transfer.*${trans_ip}" "$named"; then
			sed -i  "/allow-transfer .*localhost;/s|;|; ${trans_ip};|" "$named"
		fi
	else
		sed -i "/allow-query.*};/s|};|};\n\tallow-transfer { localhost; ${trans_ip}; };\n|" "$named"
	fi

	for backup_zone in $zones; do
		if [[ "$type" == 2 ]]; then
			if [[ ! $backup_zone == *"in-addr.arpa" ]]; then

				zone_rec=$(zone_file "$backup_zone" "$namedrfc")
				re_rec="rev.$(ipcalc -n "${trans_ip}/${backup_prefix}" | awk -F'=' '{print $2}')"

				if ! grep -q "backup.${backup_zone}." "/var/named/${zone_rec}"; then
					{
						echo "@	IN	NS		backup.${backup_zone}."
						echo "backup	IN	A		${trans_ip}"
					} >> "/var/named/${zone_rec}"
				fi

				local reverse_ip="${octets[3]}.${octets[2]}.${octets[1]}.${octets[0]}"
				local extracted_ip="${reverse_backup//.in-addr.arpa/}"

	            if ! grep -q "${reverse_ip//.${extracted_ip}}.*backup.${backup_zone}" "/var/named/${re_rec}"; then
					{
						echo "@	IN	NS	backup.${backup_zone}."
						echo "${reverse_ip//.${extracted_ip}}	IN	PTR	backup.${backup_zone}."

					} >> "/var/named/${re_rec}"
				fi
				
			fi
		elif [[ "$type" == 3 ]]; then
			pattern="/zone.*${backup_zone}/,/^}/"
			if ! sed -n "${pattern}p" "$namedrfc" | grep -q "type slave;"; then
				sed -i -e "${pattern} {s|type .*;|type slave;|}" \
						-e "${pattern} {s|file[^\"]*\"|file \"slaves/|}" \
						-e "${pattern} {s|allow-update .*};|masters {${trans_ip};};|}" "$namedrfc"
			fi
		fi
	done
	
	systemctl restart named > /dev/null 2>&1
}

forwarder_setup()
{
	if ! grep -q "BOOTPROTO=none" "$ifcfg"; then
		echo "Cấu hình IP, DNS."
		ip_setup 1
	fi
	while true; do
		read -p "Nhập địa chỉ máy chủ muốn chuyển tiếp truy vấn: " forward_ip
		if ! ip_check "$forward_ip"; then
			echo "IP không hợp lệ. Vui lòng thử lại."
		else
			break
		fi
	done
	if grep -q 'forwarders' "$named"; then
		if ! grep -q "forwarders.*${forward_ip}" "$named"; then
			sed -i  "/forwarders .*{/s|{|{ ${forward_ip};|" "$named"
		fi
	else
		sed -i "/allow-query.*};/s|};|};\n\tforwarders { ${forward_ip}; };\n|" "$named"
	fi
	sed -i -e "s/dnssec-enable.*;/dnssec-enable no;/" \
			-e "s/dnssec-validation.*;/dnssec-validation no;/" "$named"
	sed -i -e "s/SELINUX=.*/SELINUX=disabled/" "/etc/sysconfig/selinux"
}
zone_file()
{
	zone="$1"
	file="$2"

	filename=$(awk -v zone="$zone" '
		$0 ~ "zone" && $2 == "\""zone"\"" {
			in_zone = 1
		}
		in_zone && /file/ {
			match($0, /file "(.*)"/, arr)
			if (arr[1] != "") {
				print arr[1]
				exit
			}
		}
		$0 == "}" {
			in_zone = 0
		}
	' "$file")
	
	echo "$filename"
}
is_default_and_rev_zone() 
{
    local zone="$1"
	local exclude="0\.in-addr\.arpa|1\.0\.0\.127|ip6\.arpa|localhost"
    if [[ "$zone" =~ $exclude ]]; then
        return 0
    fi
    return 1
}
get_zones() 
{
    local zones=()

    while IFS= read -r line; do
        
        if [[ "$line" =~ ^zone ]]; then
            
            zone_do=$(echo "$line" | awk -F '"' '{print $2}')
            if ! is_default_and_rev_zone "$zone_do"; then
                zones+=("$zone_do") 
            fi
        fi
    done < "$namedrfc"

    echo "${zones[@]}"
}
ip_to_prefix_length() 
{
    ip="$1"
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
    
    if (( i1 >= 1 && i1 <= 126 )); then
        echo "8"   
    elif (( i1 >= 128 && i1 <= 191 )); then
        echo "16" 
    elif (( i1 >= 192 && i1 <= 223 )); then
        echo "24"  
    elif (( i1 == 127 )); then
        echo "8"   
    fi
}
ip_check()
{
	ip="$1"
	if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then	
		IFS='.' read -r i1 i2 i3 i4 <<< "$ip"

		if [[ "$i1" -ge 0 && "$i1" -le 255 && \
		  "$i2" -ge 0 && "$i2" -le 255 && \
		  "$i3" -ge 0 && "$i3" -le 255 && \
		  "$i4" -ge 0 && "$i4" -le 255 ]]; then
			  return 0
		fi
	fi
	return 1
}

prompt