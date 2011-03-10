#!/bin/bash
# snapback.sh 1.3
# Simple script to create regular snapshot-based backups for Citrix Xenserver
# Mark Round, scripts@markround.com
# http://www.markround.com/snapback
#
# 1.3 : Added basic lockfile
# 1.2 : Tidied output, removed VDIs before deleting snapshots and templates
# 1.1 : Added missing force=true paramaters to snapshot uninstall calls.

#
# Variables
#

# Temporary snapshots will be use this as a suffix
SNAPSHOT_SUFFIX=snapback
# Temporary backup templates will use this as a suffix
TEMP_SUFFIX=newbackup
# Backup templates will use this as a suffix, along with the date
BACKUP_SUFFIX=backup
# What day to run weekly backups on
WEEKLY_ON="Sun"
# What day to run monthly backups on. These will run on the first day
# specified below of the month.
MONTHLY_ON="Sun"
# Temporary file
TEMP=/tmp/snapback.$$
# UUID of the destination SR for backups
DEST_SR=e871f2df-a195-9c50-5377-be55e749c003

LOCKFILE=/tmp/snapback.lock

if [ -f $LOCKFILE ]; then
        echo "Lockfile $LOCKFILE exists, exiting!"
        exit 1
fi

touch $LOCKFILE

#
# Don't modify below this line
#

# Date format must be %Y%m%d so we can sort them
BACKUP_DATE=$(date +"%Y%m%d")

# Quick hack to grab the required paramater from the output of the xe command
function xe_param()
{
	PARAM=$1
	while read DATA; do
		LINE=$(echo $DATA | egrep "$PARAM")
		if [ $? -eq 0 ]; then
			echo "$LINE" | awk 'BEGIN{FS=": "}{print $2}'
		fi
	done

}

# Deletes a snapshot's VDIs before uninstalling it. This is needed as 
# snapshot-uninstall seems to sometimes leave "stray" VDIs in SRs
function delete_snapshot()
{
	DELETE_SNAPSHOT_UUID=$1
	for VDI_UUID in $(xe vbd-list vm-uuid=$DELETE_SNAPSHOT_UUID empty=false | xe_param "vdi-uuid"); do
        	echo "Deleting snapshot VDI : $VDI_UUID"
        	xe vdi-destroy uuid=$VDI_UUID
	done

	# Now we can remove the snapshot itself
	echo "Removing snapshot with UUID : $DELETE_SNAPSHOT_UUID"
	xe snapshot-uninstall uuid=$DELETE_SNAPSHOT_UUID force=true
}

# See above - templates also seem to leave stray VDIs around...
function delete_template()
{
	DELETE_TEMPLATE_UUID=$1
	for VDI_UUID in $(xe vbd-list vm-uuid=$DELETE_TEMPLATE_UUID empty=false | xe_param "vdi-uuid"); do
        	echo "Deleting template VDI : $VDI_UUID"
        	xe vdi-destroy uuid=$VDI_UUID
	done

	# Now we can remove the template itself
	echo "Removing template with UUID : $DELETE_TEMPLATE_UUID"
	xe template-uninstall template-uuid=$DELETE_TEMPLATE_UUID force=true
}



echo "=== Snapshot backup started at $(date) ==="
echo " "

# Get all running VMs
# todo: Need to check this works across a pool
RUNNING_VMS=$(xe vm-list power-state=running is-control-domain=false | xe_param uuid)

for VM in $RUNNING_VMS; do
	VM_NAME="$(xe vm-list uuid=$VM | xe_param name-label)"

	# Useful for testing, if we only want to process one VM
	#if [ "$VM_NAME" != "testvm" ]; then
	#	continue
	#fi

	echo " "
	echo "== Backup for $VM_NAME started at $(date) =="
	echo "= Retrieving backup paramaters ="
	SCHEDULE=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.backup)	
	RETAIN=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.retain)	
	# Not using this yet, as there are some bugs to be worked out...
	# QUIESCE=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.quiesce)	

	if [[ "$SCHEDULE" == "" || "$RETAIN" == "" ]]; then
		echo "No schedule or retention set, skipping this VM"
		continue
	fi
	echo "VM backup schedule : $SCHEDULE"
	echo "VM retention : $RETAIN previous snapshots"

	# If weekly, see if this is the correct day
	if [ "$SCHEDULE" == "weekly" ]; then
		if [ "$(date +'%a')" == "$WEEKLY_ON" ]; then
			echo "On correct day for weekly backups, running..."
		else
			echo "Weekly backups scheduled on $WEEKLY_ON, skipping..."
			continue
		fi
	fi

	# If monthly, see if this is the correct day
	if [ "$SCHEDULE" == "monthly" ]; then
		if [[ "$(date +'%a')" == "$MONTHLY_ON" && $(date '+%e') -le 7 ]]; then
			echo "On correct day for monthly backups, running..."
		else
			echo "Monthly backups scheduled on 1st $MONTHLY_ON, skipping..."
			continue
		fi
	fi
	
	echo "= Checking snapshots for $VM_NAME ="
	VM_SNAPSHOT_CHECK=$(xe snapshot-list name-label=$VM_NAME-$SNAPSHOT_SUFFIX | xe_param uuid)
	if [ "$VM_SNAPSHOT_CHECK" != "" ]; then
		echo "Found old backup snapshot : $VM_SNAPSHOT_CHECK"
		echo "Deleting..."
		delete_snapshot $VM_SNAPSHOT_CHECK
	fi
	echo "Done."

	echo "= Creating snapshot backup ="

	# Select appropriate snapshot command
	# See above - not using this yet, as have to work around failures
	#if [ "$QUIESCE" == "true" ]; then
	#	echo "Using VSS plugin"
	#	SNAPSHOT_CMD="vm-snapshot-with-quiesce"
	#else
	#	echo "Not using VSS plugin, disks will not be quiesced"
	#	SNAPSHOT_CMD="vm-snapshot"
	#fi
	SNAPSHOT_CMD="vm-snapshot"

	SNAPSHOT_UUID=$(xe $SNAPSHOT_CMD vm="$VM_NAME" new-name-label="$VM_NAME-$SNAPSHOT_SUFFIX")
	echo "Created snapshot with UUID : $SNAPSHOT_UUID"

	echo "= Copying snapshot to SR ="
	# Check there isn't a stale template with TEMP_SUFFIX name hanging around from a failed job
	TEMPLATE_TEMP="$(xe template-list name-label="$VM_NAME-$TEMP_SUFFIX" | xe_param uuid)"
	if [ "$TEMPLATE_TEMP" != "" ]; then
		echo "Found a stale temporary template, removing UUID $TEMPLATE_TEMP"
		delete_template $TEMPLATE_TEMP
	fi
	TEMPLATE_UUID=$(xe snapshot-copy uuid=$SNAPSHOT_UUID sr-uuid=$DEST_SR new-name-description="Snapshot created on $(date)" new-name-label="$VM_NAME-$TEMP_SUFFIX")
	echo "Done."

	echo "= Removing temporary snapshot backup ="
	delete_snapshot $SNAPSHOT_UUID
	echo "Done."
	
	
	# List templates for all VMs, grep for $VM_NAME-$BACKUP_SUFFIX
	# Sort -n, head -n -$RETAIN
	# Loop through and remove each one
	echo "= Removing old backups ="
	xe template-list | grep "$VM_NAME-$BACKUP_SUFFIX" | xe_param name-label | sort -n | head -n-$RETAIN > $TEMP
	while read OLD_TEMPLATE; do
		OLD_TEMPLATE_UUID=$(xe template-list name-label="$OLD_TEMPLATE" | xe_param uuid)
		echo "Removing : $OLD_TEMPLATE with UUID $OLD_TEMPLATE_UUID"
		delete_template $OLD_TEMPLATE_UUID
	done < $TEMP
	
	# Also check there is no template with the current timestamp.
	# Otherwise, you would not be able to backup more than once a day if you needed...
	TODAYS_TEMPLATE="$(xe template-list name-label="$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE" | xe_param uuid)"
	if [ "$TODAYS_TEMPLATE" != "" ]; then
		echo "Found a template already for today, removing UUID $TODAYS_TEMPLATE"
		delete_template $TODAYS_TEMPLATE
	fi

	echo "= Renaming template ="
	xe template-param-set name-label="$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE" uuid=$TEMPLATE_UUID
	echo "Done."

	echo "== Backup for $VM_NAME finished at $(date) =="
	echo " "
done

xe vdi-list sr-uuid=$DEST_SR > /var/run/sr-mount/$DEST_SR/mapping.txt
xe vbd-list > /var/run/sr-mount/$DEST_SR/vbd-mapping.txt

echo "=== Snapshot backup finished at $(date) ==="
rm $TEMP
rm $LOCKFILE
