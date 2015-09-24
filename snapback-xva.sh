#!/bin/bash
# snapback.sh 1.4
# Simple script to create regular snapshot-based backups for Citrix Xenserver
# Mark Round, scripts@markround.com
# http://www.markround.com/snapback
#
# 1.4 : Modifications by Luis Davim to support XVA backups with independent scheduling
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
TEMPLATE_SR=81548d46-4f0e-fada-927c-e2177eb49943
# UUID of the destination SR for XVA files it must be an NFS SR
XVA_SR=557dec09-333c-37be-6c1f-0e6d787b905a

LOCKFILE=/tmp/snapback.lock

#Cicle control flags
SKIP_TEMPLATE=1
SKIP_XVA=1

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


echo " "
echo "=== Snapshot backup started at $(date) ==="
echo " "

# Get all running VMs
# todo: Need to check this works across a pool
RUNNING_VMS=$(xe vm-list power-state=running is-control-domain=false | xe_param uuid)

for VM in $RUNNING_VMS; do
    VM_NAME="$(xe vm-list uuid=$VM | xe_param name-label)"

    # Useful for testing, if we only want to process one VM
    #if [ "$VM_NAME" != "testvm" ]; then
    #    continue
    #fi

    echo " "
    echo "== Backup for $VM_NAME started at $(date) =="
    echo "= Retrieving backup paramaters ="
    #Template backups
    SCHEDULE=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.backup)    
    RETAIN=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.retain)    
    #XVA Backups
    XVA_SCHEDULE=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.xva_backup)    
    XVA_RETAIN=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.xva_retain)    
    
    # Not using this yet, as there are some bugs to be worked out...
    # QUIESCE=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.quiesce)    

##############################check Template schedule###########################
    if [[ "$SCHEDULE" == "" || "$RETAIN" == "" ]]; then
        echo "No schedule or retention set for template backup, skipping this VM"
        SKIP_TEMPLATE=1
    else
        echo "VM template backup schedule : $SCHEDULE"
        echo "VM template retention       : $RETAIN previous snapshots"

        if [ "$SCHEDULE" == "daily" ]; then
            SKIP_TEMPLATE=0
        else
            # If weekly, see if this is the correct day
            if [ "$SCHEDULE" == "weekly" ]; then
                if [ "$(date +'%a')" == "$WEEKLY_ON" ]; then
                    echo "On correct day for weekly backups, running..."
                    SKIP_TEMPLATE=0
                else
                    echo "Weekly backups scheduled on $WEEKLY_ON, skipping..."
                    SKIP_TEMPLATE=1
                fi
            else
                # If monthly, see if this is the correct day
                if [ "$SCHEDULE" == "monthly" ]; then
                    if [[ "$(date +'%a')" == "$MONTHLY_ON" && $(date '+%e') -le 7 ]]; then
                        echo "On correct day for monthly backups, running..."
                        SKIP_TEMPLATE=0
                    else
                        echo "Monthly backups scheduled on 1st $MONTHLY_ON, skipping..."
                        SKIP_TEMPLATE=1
                    fi
                fi
            fi
        fi
    fi
##############################check XVA schedule################################
    if [[ "$XVA_SCHEDULE" == "" || "$XVA_RETAIN" == "" ]]; then
        echo "No schedule or retention set for XVA backup, skipping this VM"
        SKIP_XVA=1
    else
        echo "VM XVA backup schedule : $XVA_SCHEDULE"
        echo "VM XVA retention       : $XVA_RETAIN previous snapshots"

        if [ "$XVA_SCHEDULE" == "daily" ]; then
            SKIP_XVA=0
        else
            # If weekly, see if this is the correct day
            if [ "$XVA_SCHEDULE" == "weekly" ]; then
                if [ "$(date +'%a')" == "$WEEKLY_ON" ]; then
                    echo "On correct day for weekly backups, running..."
                    SKIP_XVA=0
                else
                    echo "Weekly backups scheduled on $WEEKLY_ON, skipping..."
                    SKIP_XVA=1
                fi
            else
                # If monthly, see if this is the correct day
                if [ "$XVA_SCHEDULE" == "monthly" ]; then
                    if [[ "$(date +'%a')" == "$MONTHLY_ON" && $(date '+%e') -le 7 ]]; then
                        echo "On correct day for monthly backups, running..."
                        SKIP_XVA=0
                    else
                        echo "Monthly backups scheduled on 1st $MONTHLY_ON, skipping..."
                        SKIP_XVA=1
                    fi
                fi
            fi
        fi
    fi
################################################################################

    if [[ "$SKIP_TEMPLATE" == "1" && "$SKIP_XVA" == "1" ]]; then
        echo "Nothing to do for this VM!..."
        continue
    fi
    
    echo "= Checking snapshots for $VM_NAME ="
    VM_SNAPSHOT_CHECK=$(xe snapshot-list name-label="$VM_NAME-$SNAPSHOT_SUFFIX" | xe_param uuid)
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
    #    echo "Using VSS plugin"
    #    SNAPSHOT_CMD="vm-snapshot-with-quiesce"
    #else
    #    echo "Not using VSS plugin, disks will not be quiesced"
    #    SNAPSHOT_CMD="vm-snapshot"
    #fi
    SNAPSHOT_CMD="vm-snapshot"

    SNAPSHOT_UUID=$(xe $SNAPSHOT_CMD vm="$VM_NAME" new-name-label="$VM_NAME-$SNAPSHOT_SUFFIX")
    echo "Created snapshot with UUID : $SNAPSHOT_UUID"

    #Backup to template
    if [ "$SKIP_TEMPLATE" == "0" ]; then
        echo "= Copying snapshot to SR ="
        # Check there isn't a stale template with TEMP_SUFFIX name hanging around from a failed job
        TEMPLATE_TEMP="$(xe template-list name-label="$VM_NAME-$TEMP_SUFFIX" | xe_param uuid)"
        if [ "$TEMPLATE_TEMP" != "" ]; then
            echo "Found a stale temporary template, removing UUID $TEMPLATE_TEMP"
            delete_template $TEMPLATE_TEMP
        fi
        TEMPLATE_UUID=$(xe snapshot-copy uuid=$SNAPSHOT_UUID sr-uuid=$TEMPLATE_SR new-name-description="Snapshot created on $(date)" new-name-label="$VM_NAME-$TEMP_SUFFIX")
        echo "Done."
        
        # List templates for all VMs, grep for $VM_NAME-$BACKUP_SUFFIX
        # Sort -n, head -n -$RETAIN
        # Loop through and remove each one
        echo "= Removing old template backups ="
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
    fi

    #Backup to XVA
    if [ "$SKIP_XVA" == "0" ]; then
        echo "= Exporting VM to file ="
        #Creates a XVA file from the snapshot
        EXPORT_CMD="vm-export"
        xe $EXPORT_CMD vm=$SNAPSHOT_UUID filename="/var/run/sr-mount/$XVA_SR/$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE.xva"
        echo "Done."
        
        # List XVA files for all VMs, grep for $VM_NAME-$BACKUP_SUFFIX
        # Sort -n, head -n -$RETAIN
        # Loop through and remove each one
        echo "= Removing old XVA files ="
        ls -1 /var/run/sr-mount/$XVA_SR/*.xva | grep "$VM_NAME-$BACKUP_SUFFIX" | sort -n | head -n-$XVA_RETAIN > $TEMP
        while read OLD_TEMPLATE; do
            echo "Removing : $OLD_TEMPLATE"
            rm $OLD_TEMPLATE
        done < $TEMP
    fi

    echo "= Removing temporary snapshot backup ="
    delete_snapshot $SNAPSHOT_UUID
    echo "Done."

    echo "== Backup for $VM_NAME finished at $(date) =="
    echo " "
done

xe vdi-list sr-uuid=$TEMPLATE_SR > /var/run/sr-mount/$TEMPLATE_SR/mapping.txt
xe vbd-list > /var/run/sr-mount/$TEMPLATE_SR/vbd-mapping.txt

echo "=== Snapshot backup finished at $(date) ==="
echo " "
echo "=== Metadata backup started at $(date) ==="
echo " "
#Backup Pool meta-data:
xe-backup-metadata -c -k 10 -u $TEMPLATE_SR 

echo "=== Metadata backup finished at $(date) ==="
echo " "

rm $TEMP
rm $LOCKFILE
