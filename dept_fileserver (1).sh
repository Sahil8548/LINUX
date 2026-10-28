#!/bin/bash
# =====================================================================
# Department File Server Management System
# Linux Micro Project - Bash Shell Scripting
#
# Features:
# - Create secure shared directories for departments
# - Ownership and permission management (chown / chmod / setgid)
# - Access Control Lists (setfacl / getfacl)
# - Storage quota allocation (kernel quota if available, otherwise
# script-level quota enforcement using du)
# - Usage monitoring, reports and automated testing report
#
# Run with: sudo ./dept_fileserver.sh
# =====================================================================
BASE_DIR="${BASE_DIR:-/srv/departments}"
DATA_DIR="${DATA_DIR:-/var/lib/dept_fileserver}"
REPORT_DIR="$DATA_DIR/reports"
DEPT_DB="$DATA_DIR/departments.db" # name|group|path|quota_mb|created
USER_DB="$DATA_DIR/dept_users.db" # username|department
LOG_FILE="${LOG_FILE:-/var/log/dept_fileserver.log}"
DEFAULT_QUOTA_MB=100
# ---------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------
log_action() {
echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" >> "$LOG_FILE"
}
pause() {
echo
read -rp "Press Enter to continue..." _
}
check_root() {
if [ "$EUID" -ne 0 ]; then
echo "This program must be run as root."
echo "Usage: sudo $0"


exit 1
fi
}
check_dependencies() {
local missing=0
local cmd
for cmd in groupadd groupdel useradd usermod gpasswd chown chmod du df \
stat getent awk grep sed runuser passwd; do
if ! command -v "$cmd" >/dev/null 2>&1; then
echo "Required command not found: $cmd"
missing=1
fi
done
if [ "$missing" -eq 1 ]; then
exit 1
fi
if ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
echo "The 'acl' package (setfacl/getfacl) is not installed."
read -rp "Install it now using apt? (y/n): " ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
apt-get update -qq && apt-get install -y acl
fi
if ! command -v setfacl >/dev/null 2>&1; then
echo "ACL tools are required. Install with: sudo apt install acl"
exit 1
fi
fi
}
init_system() {
mkdir -p "$BASE_DIR" "$DATA_DIR" "$REPORT_DIR"
touch "$DEPT_DB" "$USER_DB" "$LOG_FILE"
chown root:root "$BASE_DIR" "$DATA_DIR"
chmod 755 "$BASE_DIR"
chmod 700 "$DATA_DIR"
chmod 640 "$LOG_FILE"
}
# ---------------------------------------------------------------------
# Validation functions
# ---------------------------------------------------------------------
valid_name() {
[[ "$1" =~ ^[a-z][a-z0-9_]{1,19}$ ]]
}
valid_user() {
[[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}
valid_number() {
[[ "$1" =~ ^[1-9][0-9]{0,8}$ ]]
}
valid_perm() {
[[ "$1" =~ ^[r-][w-][x-]$ ]]
}
# ---------------------------------------------------------------------
# Database helper functions
# ---------------------------------------------------------------------
dept_exists() {
grep -q "^$1|" "$DEPT_DB"
}
# get_field <department> <field-number>
get_field() {
awk -F'|' -v d="$1" -v f="$2" '$1==d {print $f}' "$DEPT_DB"
}
count_members() {
awk -F'|' -v d="$1" '$2==d' "$USER_DB" | wc -l
}
# Asks the user to pick a department. Result is stored in $DEPT
choose_dept() {
if [ ! -s "$DEPT_DB" ]; then
echo "No departments exist yet. Create one first (menu option 1)."


return 1
fi
echo "Available departments:"
cut -d'|' -f1 "$DEPT_DB" | sed 's/^/ - /'
read -rp "Enter department name: " DEPT
DEPT=$(echo "$DEPT" | tr 'A-Z' 'a-z')
if ! valid_name "$DEPT" || ! dept_exists "$DEPT"; then
echo "Department '$DEPT' not found."
return 1
fi
return 0
}
# Used space of a directory in KB
usage_kb() {
du -sk "$1" 2>/dev/null | awk '{print $1}'
}
# ---------------------------------------------------------------------
# Quota helper (kernel group quota if the filesystem supports it)
# ---------------------------------------------------------------------
apply_kernel_quota() {
local group="$1" quota_mb="$2" path="$3"
local mp hard_kb
if ! command -v setquota >/dev/null 2>&1 || ! command -v quotaon >/dev/null 2>&1; then
echo " [info] Quota tools not installed - using script-level quota enforcement."
return 1
fi
mp=$(df --output=target "$path" | tail -n 1)
if quotaon -pg "$mp" 2>/dev/null | grep -q "is on"; then
hard_kb=$(( quota_mb * 1024 ))
if setquota -g "$group" "$hard_kb" "$hard_kb" 0 0 "$mp" 2>/dev/null; then
echo " [ok] Kernel group quota applied on $mp"
return 0
fi
fi
echo " [info] Kernel quota not enabled on $mp - using script-level quota enforcement."
return 1
}
# ---------------------------------------------------------------------
# 1. Create department directory
# ---------------------------------------------------------------------
create_department() {
echo "=== Create Department Directory ==="
read -rp "Department name (lowercase letters, digits, _ ; 2-20 chars): " name
name=$(echo "$name" | tr 'A-Z' 'a-z')
if ! valid_name "$name"; then
echo "Invalid department name."
return
fi
if dept_exists "$name"; then
echo "Department '$name' already exists."
return
fi
read -rp "Storage quota in MB [$DEFAULT_QUOTA_MB]: " quota
quota=${quota:-$DEFAULT_QUOTA_MB}
if ! valid_number "$quota"; then
echo "Invalid quota. Enter a positive whole number."
return
fi
local group="dept_$name"
local path="$BASE_DIR/$name"
if ! getent group "$group" >/dev/null 2>&1; then
if ! groupadd "$group"; then
echo "Failed to create group $group."
return
fi
fi
if ! mkdir -p "$path"; then
echo "Failed to create directory $path."
return


fi
chown root:"$group" "$path"
chmod 2770 "$path"
echo "$name|$group|$path|$quota|$(date '+%Y-%m-%d %H:%M:%S')" >> "$DEPT_DB"
apply_kernel_quota "$group" "$quota" "$path"
log_action "CREATE department=$name group=$group path=$path quota=${quota}MB"
echo
echo "Department created successfully:"
echo " Name : $name"
echo " Group : $group"
echo " Directory : $path"
echo " Quota : ${quota} MB"
echo " Mode : 2770 (owner+group full access, others none, setgid on)"
}
# ---------------------------------------------------------------------
# 2. List departments
# ---------------------------------------------------------------------
list_departments() {
echo "=== Department List ==="
if [ ! -s "$DEPT_DB" ]; then
echo "No departments found."
return
fi
printf "%-14s %-16s %-10s %-6s %-10s %-8s\n" "DEPARTMENT" "GROUP" "OWNER" "MODE" "QUOTA(MB)" "MEMBERS"
printf "%-14s %-16s %-10s %-6s %-10s %-8s\n" "----------" "-----" "-----" "----" "---------" "-------"
local name group path quota created owner mode members
while IFS='|' read -r name group path quota created; do
owner=$(stat -c '%U' "$path" 2>/dev/null)
mode=$(stat -c '%a' "$path" 2>/dev/null)
members=$(count_members "$name")
printf "%-14s %-16s %-10s %-6s %-10s %-8s\n" "$name" "$group" "${owner:-?}" "${mode:-?}" "$quota" "$members"
done < "$DEPT_DB"
}
# ---------------------------------------------------------------------
# 3. Add user to department
# ---------------------------------------------------------------------
add_user_to_dept() {
echo "=== Add User to Department ==="
choose_dept || return
read -rp "Username to add: " user
if ! valid_user "$user"; then
echo "Invalid username."
return
fi
if ! id "$user" >/dev/null 2>&1; then
read -rp "User '$user' does not exist. Create it now? (y/n): " ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
if ! useradd -m -s /bin/bash "$user"; then
echo "Failed to create user."
return
fi
echo "Set a password for $user:"
passwd "$user"
log_action "USERADD user=$user"
else
return
fi
fi
local group
group=$(get_field "$DEPT" 2)
if usermod -aG "$group" "$user"; then
if ! grep -qxF "$user|$DEPT" "$USER_DB"; then
echo "$user|$DEPT" >> "$USER_DB"
fi
log_action "ADDUSER user=$user department=$DEPT"
echo "User '$user' added to department '$DEPT' (group $group)."
echo "Note: the user must log in again for the new group to take effect."
else
echo "Failed to add user to group."
fi
}


# ---------------------------------------------------------------------
# 4. Remove user from department
# ---------------------------------------------------------------------
remove_user_from_dept() {
echo "=== Remove User from Department ==="
choose_dept || return
echo "Members of $DEPT:"
awk -F'|' -v d="$DEPT" '$2==d {print " - " $1}' "$USER_DB"
read -rp "Username to remove: " user
if ! valid_user "$user"; then
echo "Invalid username."
return
fi
if ! grep -qxF "$user|$DEPT" "$USER_DB"; then
echo "User '$user' is not a member of '$DEPT'."
return
fi
local group
group=$(get_field "$DEPT" 2)
gpasswd -d "$user" "$group" >/dev/null 2>&1
grep -vxF "$user|$DEPT" "$USER_DB" > "$USER_DB.tmp"
mv "$USER_DB.tmp" "$USER_DB"
chmod 600 "$USER_DB"
log_action "REMOVEUSER user=$user department=$DEPT"
echo "User '$user' removed from department '$DEPT'."
}
# ---------------------------------------------------------------------
# 5. Set directory ownership
# ---------------------------------------------------------------------
set_ownership() {
echo "=== Set Directory Ownership ==="
choose_dept || return
local path group
path=$(get_field "$DEPT" 3)
group=$(get_field "$DEPT" 2)
echo "Current ownership:"
ls -ld "$path"
read -rp "New owner (department manager) username: " owner
if ! valid_user "$owner" || ! id "$owner" >/dev/null 2>&1; then
echo "User '$owner' does not exist."
return
fi
if chown "$owner":"$group" "$path"; then
log_action "CHOWN department=$DEPT owner=$owner group=$group"
echo "Ownership updated:"
ls -ld "$path"
else
echo "Failed to change ownership."
fi
}
# ---------------------------------------------------------------------
# 6. Set directory permissions
# ---------------------------------------------------------------------
set_permissions() {
echo "=== Set Directory Permissions ==="
choose_dept || return
local path mode
path=$(get_field "$DEPT" 3)
echo "Current permissions:"
ls -ld "$path"
echo
echo "Choose a permission preset:"
echo " 1) 2770 - Private: owner and group full access, others none (recommended)"
echo " 2) 2750 - Group read-only (members can read, only owner can write)"
echo " 3) 3770 - Shared with sticky bit (users can delete only their own files)"
echo " 4) Custom octal mode"


read -rp "Choice: " pchoice
case "$pchoice" in
1) mode=2770 ;;
2) mode=2750 ;;
3) mode=3770 ;;
4)
read -rp "Enter octal mode (e.g. 2770): " mode
if ! [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
echo "Invalid octal mode."
return
fi
;;
*)
echo "Invalid choice."
return
;;
esac
if chmod "$mode" "$path"; then
log_action "CHMOD department=$DEPT mode=$mode"
echo "Permissions updated:"
ls -ld "$path"
else
echo "Failed to change permissions."
fi
}
# ---------------------------------------------------------------------
# 7. Configure ACL
# ---------------------------------------------------------------------
manage_acl() {
echo "=== Configure ACL ==="
choose_dept || return
local path
path=$(get_field "$DEPT" 3)
local achoice target perm
while true; do
echo
echo "---- ACL Menu for '$DEPT' ----"
echo "1) Grant access to a user"
echo "2) Grant access to a group"
echo "3) Remove a user ACL entry"
echo "4) Remove a group ACL entry"
echo "5) View current ACL"
echo "6) Remove ALL ACL entries (reset to 2770)"
echo "0) Back to main menu"
read -rp "Choice: " achoice
case "$achoice" in
1)
read -rp "Username: " target
if ! valid_user "$target" || ! id "$target" >/dev/null 2>&1; then
echo "User does not exist."
continue
fi
read -rp "Permissions (e.g. rwx, r-x, r--): " perm
if ! valid_perm "$perm"; then
echo "Invalid permission string."
continue
fi
setfacl -m "u:$target:$perm" "$path" && \
setfacl -d -m "u:$target:$perm" "$path" && \
{ echo "ACL set: user $target = $perm (also as default for new files)"; \
log_action "ACL user=$target perm=$perm department=$DEPT"; }
;;
2)
read -rp "Group name: " target
if ! valid_user "$target" || ! getent group "$target" >/dev/null 2>&1; then
echo "Group does not exist."
continue
fi
read -rp "Permissions (e.g. rwx, r-x, r--): " perm
if ! valid_perm "$perm"; then
echo "Invalid permission string."
continue
fi
setfacl -m "g:$target:$perm" "$path" && \


setfacl -d -m "g:$target:$perm" "$path" && \
{ echo "ACL set: group $target = $perm (also as default for new files)"; \
log_action "ACL group=$target perm=$perm department=$DEPT"; }
;;
3)
read -rp "Username to remove from ACL: " target
if ! valid_user "$target"; then
echo "Invalid username."
continue
fi
setfacl -x "u:$target" "$path" 2>/dev/null
setfacl -d -x "u:$target" "$path" 2>/dev/null
echo "ACL entry for user $target removed (if it existed)."
log_action "ACL-REMOVE user=$target department=$DEPT"
;;
4)
read -rp "Group name to remove from ACL: " target
if ! valid_user "$target"; then
echo "Invalid group name."
continue
fi
setfacl -x "g:$target" "$path" 2>/dev/null
setfacl -d -x "g:$target" "$path" 2>/dev/null
echo "ACL entry for group $target removed (if it existed)."
log_action "ACL-REMOVE group=$target department=$DEPT"
;;
5)
echo
getfacl -p "$path"
;;
6)
setfacl -b "$path"
chmod 2770 "$path"
echo "All ACL entries removed. Mode reset to 2770."
log_action "ACL-RESET department=$DEPT"
;;
0)
return
;;
*)
echo "Invalid choice."
;;
esac
done
}
# ---------------------------------------------------------------------
# 8. Allocate / change storage quota
# ---------------------------------------------------------------------
allocate_storage() {
echo "=== Allocate / Change Storage Quota ==="
choose_dept || return
local path group current used_kb used_mb
path=$(get_field "$DEPT" 3)
group=$(get_field "$DEPT" 2)
current=$(get_field "$DEPT" 4)
used_kb=$(usage_kb "$path")
used_mb=$(( ${used_kb:-0} / 1024 ))
echo "Current quota : ${current} MB"
echo "Currently used: ${used_mb} MB"
read -rp "New quota in MB: " newq
if ! valid_number "$newq"; then
echo "Invalid quota. Enter a positive whole number."
return
fi
if [ "$newq" -lt "$used_mb" ]; then
echo "Warning: new quota is smaller than current usage (${used_mb} MB)."
echo "The department will be flagged as OVER QUOTA."
fi
awk -F'|' -v OFS='|' -v d="$DEPT" -v q="$newq" '$1==d {$4=q} {print}' "$DEPT_DB" > "$DEPT_DB.tmp"
mv "$DEPT_DB.tmp" "$DEPT_DB"
chmod 600 "$DEPT_DB"
apply_kernel_quota "$group" "$newq" "$path"
log_action "QUOTA department=$DEPT old=${current}MB new=${newq}MB"


echo "Quota for '$DEPT' changed from ${current} MB to ${newq} MB."
local total avail
total=$(awk -F'|' '{s+=$4} END {print s+0}' "$DEPT_DB")
avail=$(df -m --output=avail "$BASE_DIR" | tail -n 1 | tr -d ' ')
echo "Total allocated to all departments: ${total} MB"
echo "Free space on disk : ${avail} MB"
if [ "$total" -gt "$avail" ]; then
echo "Warning: total allocation exceeds the free disk space (over-provisioned)."
fi
}
# ---------------------------------------------------------------------
# 9. Show storage usage
# ---------------------------------------------------------------------
show_usage() {
echo "=== Storage Usage ==="
if [ ! -s "$DEPT_DB" ]; then
echo "No departments found."
return
fi
printf "%-14s %10s %10s %7s %s\n" "DEPARTMENT" "QUOTA(MB)" "USED(MB)" "USED%" "STATUS"
printf "%-14s %10s %10s %7s %s\n" "----------" "---------" "--------" "-----" "------"
local name group path quota created used_kb quota_kb pct used_mb status
while IFS='|' read -r name group path quota created; do
used_kb=$(usage_kb "$path")
used_kb=${used_kb:-0}
quota_kb=$(( quota * 1024 ))
pct=$(( used_kb * 100 / quota_kb ))
used_mb=$(( used_kb / 1024 ))
if [ "$used_kb" -gt "$quota_kb" ]; then
status="OVER QUOTA"
elif [ "$pct" -ge 80 ]; then
status="WARNING (>=80%)"
else
status="OK"
fi
printf "%-14s %10s %10s %6s%% %s\n" "$name" "$quota" "$used_mb" "$pct" "$status"
done < "$DEPT_DB"
echo
echo "Disk space of $BASE_DIR:"
df -h "$BASE_DIR"
}
# ---------------------------------------------------------------------
# 10. Enforce quotas (lock departments that exceed their quota)
# ---------------------------------------------------------------------
enforce_quotas() {
echo "=== Enforce Quotas ==="
if [ ! -s "$DEPT_DB" ]; then
echo "No departments found."
return
fi
local name group path quota created used_kb quota_kb mode
while IFS='|' read -r name group path quota created; do
used_kb=$(usage_kb "$path")
used_kb=${used_kb:-0}
quota_kb=$(( quota * 1024 ))
mode=$(stat -c '%a' "$path" 2>/dev/null)
if [ "$used_kb" -gt "$quota_kb" ]; then
if [ "$mode" != "2550" ]; then
chmod 2550 "$path"
log_action "LOCK department=$name (over quota)"
echo "[LOCKED] $name is over quota - write access removed (mode 2550)."
else
echo "[LOCKED] $name is still over quota."
fi
else
if [ "$mode" = "2550" ]; then
chmod 2770 "$path"
log_action "UNLOCK department=$name (under quota)"
echo "[UNLOCKED] $name is under quota - write access restored (mode 2770)."
else
echo "[OK] $name is within its quota."
fi
fi
done < "$DEPT_DB"
}


# ---------------------------------------------------------------------
# 11. Generate report
# ---------------------------------------------------------------------
build_report() {
echo "====================================================================="
echo " DEPARTMENT FILE SERVER - STORAGE AND ACCESS REPORT"
echo "====================================================================="
echo "Generated on : $(date '+%Y-%m-%d %H:%M:%S')"
echo "Server : $(hostname)"
echo "Generated by : $(whoami)"
echo "Base folder : $BASE_DIR"
echo "====================================================================="
echo
if [ ! -s "$DEPT_DB" ]; then
echo "No departments configured."
return
fi
local name group path quota created used_kb quota_kb pct owner mode
local total_quota=0 total_used_kb=0 count=0
while IFS='|' read -r name group path quota created; do
used_kb=$(usage_kb "$path")
used_kb=${used_kb:-0}
quota_kb=$(( quota * 1024 ))
pct=$(( used_kb * 100 / quota_kb ))
owner=$(stat -c '%U' "$path" 2>/dev/null)
mode=$(stat -c '%a' "$path" 2>/dev/null)
echo "Department : $name"
echo " Created : $created"
echo " Directory : $path"
echo " Owner : ${owner:-unknown}"
echo " Group : $group"
echo " Mode : ${mode:-unknown}"
echo " Quota : ${quota} MB"
echo " Used : $(( used_kb / 1024 )) MB (${pct}%)"
if [ "$used_kb" -gt "$quota_kb" ]; then
echo " Status : OVER QUOTA"
else
echo " Status : Within quota"
fi
echo " Members :"
if [ "$(count_members "$name")" -eq 0 ]; then
echo " (none)"
else
awk -F'|' -v d="$name" '$2==d {print " " $1}' "$USER_DB"
fi
echo " ACL entries:"
getfacl -p "$path" 2>/dev/null | grep -v '^#' | grep -v '^$' | sed 's/^/ /'
echo "---------------------------------------------------------------------"
total_quota=$(( total_quota + quota ))
total_used_kb=$(( total_used_kb + used_kb ))
count=$(( count + 1 ))
done < "$DEPT_DB"
echo
echo "SUMMARY"
echo " Total departments : $count"
echo " Total quota : ${total_quota} MB"
echo " Total used : $(( total_used_kb / 1024 )) MB"
echo
echo "Disk information:"
df -h "$BASE_DIR"
}
generate_report() {
local file="$REPORT_DIR/report_$(date +%Y%m%d_%H%M%S).txt"
build_report > "$file"
cat "$file"
echo
echo "Report saved to: $file"
log_action "REPORT generated file=$file"
}
# ---------------------------------------------------------------------
# 12. Testing report (automated tests)


# ---------------------------------------------------------------------
PASS=0
FAIL=0
test_result() {
# $1 = description, $2 = exit status (0 = pass)
if [ "$2" -eq 0 ]; then
echo " [PASS] $1"
PASS=$(( PASS + 1 ))
else
echo " [FAIL] $1"
FAIL=$(( FAIL + 1 ))
fi
}
run_tests_body() {
PASS=0
FAIL=0
echo "====================================================================="
echo " DEPARTMENT FILE SERVER - TESTING REPORT"
echo "====================================================================="
echo "Date : $(date '+%Y-%m-%d %H:%M:%S')"
echo "====================================================================="
if [ ! -s "$DEPT_DB" ]; then
echo "No departments to test. Create a department first."
return
fi
local name group path quota created perms others used_kb quota_kb member tmpfile fgroup
while IFS='|' read -r name group path quota created; do
echo
echo "Testing department: $name"
[ -d "$path" ]
test_result "Directory exists ($path)" $?
getent group "$group" >/dev/null 2>&1
test_result "Group exists ($group)" $?
[ -g "$path" ]
test_result "Setgid bit is set (new files inherit the group)" $?
perms=$(stat -c '%a' "$path" 2>/dev/null)
others=${perms: -1}
[ "$others" = "0" ]
test_result "Others have no access (mode $perms)" $?
getfacl -p "$path" >/dev/null 2>&1
test_result "ACL is supported and readable" $?
[[ "$quota" =~ ^[0-9]+$ ]]
test_result "Quota is recorded (${quota} MB)" $?
used_kb=$(usage_kb "$path")
used_kb=${used_kb:-0}
quota_kb=$(( quota * 1024 ))
[ "$used_kb" -le "$quota_kb" ]
test_result "Usage is within quota" $?
if runuser -u nobody -- ls "$path" >/dev/null 2>&1; then
test_result "Outsider user 'nobody' is denied access" 1
else
test_result "Outsider user 'nobody' is denied access" 0
fi
member=$(awk -F'|' -v d="$name" '$2==d {print $1; exit}' "$USER_DB")
if [ -n "$member" ] && id "$member" >/dev/null 2>&1; then
tmpfile="$path/.fs_test_$$"
if runuser -u "$member" -- touch "$tmpfile" >/dev/null 2>&1; then
test_result "Member '$member' can create files" 0
fgroup=$(stat -c '%G' "$tmpfile" 2>/dev/null)
[ "$fgroup" = "$group" ]
test_result "New file inherits group $group" $?
rm -f "$tmpfile"
else
test_result "Member '$member' can create files" 1
fi
else
echo " [SKIP] No members in this department - write test skipped"


fi
done < "$DEPT_DB"
echo
echo "====================================================================="
echo " TOTAL PASSED : $PASS"
echo " TOTAL FAILED : $FAIL"
echo "====================================================================="
}
run_tests() {
local file="$REPORT_DIR/testing_report_$(date +%Y%m%d_%H%M%S).txt"
run_tests_body | tee "$file"
echo
echo "Testing report saved to: $file"
log_action "TEST report generated file=$file"
}
# ---------------------------------------------------------------------
# 13. View activity log
# ---------------------------------------------------------------------
view_log() {
echo "=== Activity Log (last 25 entries) ==="
if [ -s "$LOG_FILE" ]; then
tail -n 25 "$LOG_FILE"
else
echo "Log is empty."
fi
}
# ---------------------------------------------------------------------
# 14. Delete department
# ---------------------------------------------------------------------
delete_department() {
echo "=== Delete Department ==="
choose_dept || return
local path group
path=$(get_field "$DEPT" 3)
group=$(get_field "$DEPT" 2)
case "$path" in
"$BASE_DIR"/?*) ;;
*)
echo "Refusing to delete unsafe path: $path"
return
;;
esac
echo "This will permanently delete '$path' and ALL its files."
read -rp "Type DELETE to confirm: " confirm
if [ "$confirm" != "DELETE" ]; then
echo "Cancelled."
return
fi
rm -rf -- "$path"
groupdel "$group" 2>/dev/null
awk -F'|' -v d="$DEPT" '$1!=d' "$DEPT_DB" > "$DEPT_DB.tmp"
mv "$DEPT_DB.tmp" "$DEPT_DB"
awk -F'|' -v d="$DEPT" '$2!=d' "$USER_DB" > "$USER_DB.tmp"
mv "$USER_DB.tmp" "$USER_DB"
chmod 600 "$DEPT_DB" "$USER_DB"
log_action "DELETE department=$DEPT"
echo "Department '$DEPT' deleted."
}
# ---------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------
show_menu() {
echo
echo "====================================================="
echo " DEPARTMENT FILE SERVER MANAGEMENT SYSTEM"
echo "====================================================="
echo " 1) Create Department Directory"
echo " 2) List Departments"
echo " 3) Add User to Department"


echo " 4) Remove User from Department"
echo " 5) Set Directory Ownership"
echo " 6) Set Directory Permissions"
echo " 7) Configure ACL"
echo " 8) Allocate / Change Storage Quota"
echo " 9) Show Storage Usage"
echo " 10) Enforce Quotas"
echo " 11) Generate Report"
echo " 12) Run Testing Report"
echo " 13) View Activity Log"
echo " 14) Delete Department"
echo " 0) Exit"
echo "====================================================="
}
main() {
check_root
check_dependencies
init_system
local choice
while true; do
show_menu
read -rp "Enter your choice: " choice
echo
case "$choice" in
1) create_department ;;
2) list_departments ;;
3) add_user_to_dept ;;
4) remove_user_from_dept ;;
5) set_ownership ;;
6) set_permissions ;;
7) manage_acl ;;
8) allocate_storage ;;
9) show_usage ;;
10) enforce_quotas ;;
11) generate_report ;;
12) run_tests ;;
13) view_log ;;
14) delete_department ;;
0)
echo "Goodbye!"
exit 0
;;
*)
echo "Invalid choice. Please enter a number from 0 to 14."
;;
esac
pause
done
}
main

