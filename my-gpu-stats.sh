#!/usr/bin/env bash
# Usage: gpu-stats internal|amd|nvidia
# GPU temps, fans, power, load

#DEBUG=1
TIMEOUT_AMD=2 # per each value per each GPU
TIMEOUT_NVIDIA=30 # per all GPU at once

set -o pipefail

[[ -z $GPU_DETECT_JSON ]] &&
	source /etc/environment

[[ ! -f $GPU_DETECT_JSON ]] &&
	echo "No $GPU_DETECT_JSON file exists" >&2 &&
	exit 1

# Preventing from running nvidia tools if necessary
[[ -f /run/hive/NV_OFF ]] && NV_OFF=1 || NV_OFF=0


NVIDIA_STATS=

json=`cat $GPU_DETECT_JSON`

# fill some arrays from gpu-detect
#keys=(`echo "$json" | jq -r ". | to_entries[] | .key"`)
busids=(`echo "$json" | jq -r ".[] | .busid"`)
brands=(`echo "$json" | jq -r ".[] | .brand"`)

#temps=()
#fans=()
powers=()
#loads=()
#jtemps=()
#mtemps=()


function put_stats() { # @index, @temp, @fan, @power, @load, @jtemp, @mtemp
	[[ -z $1 ]] && return 1
	[[ ! -z "$2" ]] && temps[$1]="$2"  || temps[$1]=0
	[[ ! -z "$3" ]] && fans[$1]="$3"   || fans[$1]=0
	[[ ! -z "$4" ]] && powers[$1]="$4" || powers[$1]=0
	[[ ! -z "$5" ]] && loads[$1]="$5"  || loads[$1]=0
	[[ ! -z "$6" ]] && jtemps[$1]="$6" || jtemps[$1]=0
	[[ ! -z "$7" ]] && mtemps[$1]="$7" || mtemps[$1]=0
}


function amd_stats() { # @arr_index
	[[ `echo /sys/bus/pci/devices/0000:${busids[$1]}/drm/card*/ 2>/dev/null` =~ \/card([0-9]+)\/ ]]
	cardno=${BASH_REMATCH[1]}
	[[ -z "$cardno" ]] && echo "Error: can not match card id for GPU#$1 ${busids[$1]}" >&2 && return 1

	hwmondir=`realpath /sys/class/drm/card$cardno/device/hwmon/hwmon*/` || return 1

	local speed=0
	if [[ -e ${hwmondir}/pwm1 ]]; then
		#[[ -e ${hwmondir}/pwm1_max ]] && fanmax=`head -1 ${hwmondir}/pwm1_max` || fanmax=255
		#[[ -e ${hwmondir}/pwm1_min ]] && fanmin=`head -1 ${hwmondir}/pwm1_min` || fanmin=0
		local fanmax=`echo "$json" | jq -r ".[$1] | if .fanmax==null then 255 else .fanmax end"`
		local fanmin=`echo "$json" | jq -r ".[$1] | if .fanmin==null then 0 else .fanmin end"`
		fan=`timeout --foreground -s9 $TIMEOUT_AMD head -1 ${hwmondir}/pwm1`
		[[ $fan -gt $fanmin && $fanmax -gt $fanmin ]] && speed=$(( (fan - fanmin) * 100 / (fanmax - fanmin) )) || speed=0
	else
		echo "Error: fan speed unknown for card $cardno" >&2
	fi

	local rpm=0
	if [[ $speed -eq 100 ]]; then
		if [[ -e ${hwmondir}/fan1_input ]]; then
			rpm=`timeout --foreground -s9 $TIMEOUT_AMD head -1 ${hwmondir}/fan1_input`
			[[ $rpm -eq 65535 ]] && speed=0 # driver bug
		else
			echo "Error: RPM unknown for card $cardno" >&2
		fi
	fi

	local amdgpu_pm_info=()
	declare -A PMINFO=()
	if [[ -e /sys/kernel/debug/dri/$cardno/amdgpu_pm_info ]]; then
		readarray -t amdgpu_pm_info < /sys/kernel/debug/dri/$cardno/amdgpu_pm_info
		# convert into associative array
		for line in "${amdgpu_pm_info[@]}"; do
			if [[ "$line" =~ ([^:]+):\ ([0-9]+) ]]; then
				PMINFO["${BASH_REMATCH[1]// }"]="${BASH_REMATCH[2]}"
			elif [[ "$line" =~ ([0-9]+)[^\(]+\(([^\)]+) ]]; then
				PMINFO["${BASH_REMATCH[2]// }"]="${BASH_REMATCH[1]}"
			fi
		done
		#echo "${PMINFO[GPUTemperature]}C, ${PMINFO[averageGPU]}W, ${PMINFO[GPULoad]}%, ${PMINFO[MEMLoad]}%" >&2
	fi

	local power="${PMINFO[averageGPU]}"
	if [[ -z "$power" ]]; then
		if [[ -e ${hwmondir}/power1_average ]]; then
			power=`timeout --foreground -s9 $TIMEOUT_AMD head -1 ${hwmondir}/power1_average`
			power=$(( power / 1000 / 1000 ))
		else
			echo "Error: power unknown for card $cardno" >&2
		fi
	fi

	local load="${PMINFO[GPULoad]}"
	if [[ -z "$load" ]]; then
		# it works only on newer drivers
		if [[ -e /sys/class/drm/card${cardno}/device/gpu_busy_percent ]]; then
			load=`timeout --foreground -s9 $TIMEOUT_AMD head -1 /sys/class/drm/card${cardno}/device/gpu_busy_percent`
		#else
		#	echo "Error: power unknown for card $cardno" >&2
		fi
	fi

	local mload="${PMINFO[MEMLoad]}"

	local temp="${PMINFO[GPUTemperature]}"
	if [[ -z "$temp" ]]; then
		if [[ -e ${hwmondir}/temp1_input ]]; then
			temp=`timeout --foreground -s9 $TIMEOUT_AMD head -1 ${hwmondir}/temp1_input`
			temp=$(( temp / 1000 ))
		else
			echo "Error: temp unknown for card $cardno" >&2
		fi
	fi

	local jtemp=0
	if [[ -e ${hwmondir}/temp2_input ]]; then
		jtemp=`timeout --foreground -s9 $TIMEOUT_AMD head -1 ${hwmondir}/temp2_input`
		jtemp=$(( jtemp / 1000 ))
	#else
	#	echo "Error: jtemp unknown for card $cardno" >&2
	fi

	local mtemp=0
	if [[ -e ${hwmondir}/temp3_input ]]; then
		mtemp=`timeout --foreground -s9 $TIMEOUT_AMD head -1 ${hwmondir}/temp3_input`
		mtemp=$(( mtemp / 1000 ))
	#else
	#	echo "Error: mtemp unknown for card $cardno" >&2
	fi

	put_stats "$1" "$temp" "$speed" "$power" "$load" "$jtemp" "$mtemp"

	[[ "$DEBUG" == "1" ]] &&
		echo "GPU#$1	${busids[$1]}	${temp}C	${speed}%	${power}W	${load}%	${jtemp}C	${mtemp}C	$rpm" >&2
	return 0
}


function nvidia_stats() { # @arr_index
	if [[ -z "$NVIDIA_STATS" ]]; then
		[[ $NV_OFF -eq 1 ]] && return 1

		# timeout should be high enough on systems under load
		NVIDIA_STATS=`timeout --foreground -s9 $TIMEOUT_NVIDIA \
			nvtool --csv --quiet --busid --device --statuscode --temp --fanspeed --power --usage --status`
		exitcode=$?
		if [[ $exitcode -ne 0 ]]; then
			[[ -z "$NVIDIA_STATS" ]] && NVIDIA_STATS=" " # prevent query for every gpu
			echo "nvtool error ($exitcode)" >&2
			#return 1
		fi
	fi

	IFS=";" read busid index status temp speed power cload mload msg < <( echo "$NVIDIA_STATS" | grep -i "00000000:${busids[$1]}" )
	[[ -z "$busid" ]] && return 1
	[[ "$status" -ne 0 ]] && echo "GPU#$index ${busids[$1]} - $msg ($status)" >&2
	put_stats "$1" "$temp" "$speed" `printf %.0f "$power"` "$cload"

	[[ "$DEBUG" == "1" ]] &&
		echo "GPU#$1	${busids[$1]}	${temp}C	${speed}%	${power}W	${cload}%	${jtemp}C	${mtemp}C	$[$status]" >&2
	return 0
}


cnt=${#busids[@]}
for (( i=0; i < $cnt; i++)); do
	if [[ "${brands[$i]}" == "amd" && ( -z $1 || "$1" == "amd") ]]; then
		amd_stats $i && continue
	elif [[ "${brands[$i]}" == "nvidia" && ( -z $1 || "$1" == "nvidia") ]]; then
		nvidia_stats $i && continue
	elif [[ "${brands[$i]}" == "cpu" && ( -z $1 || "$1" == "internal") ]]; then
		# return zero stats
		put_stats $i
		continue
	else # remove arrays data for this item
		unset busids[$i]
		unset brands[$i]
		continue
	fi
	# return zero stats on gpu errors
	put_stats $i
done


if [[ "$DEBUG" == "1" ]]; then
	echo "count: $cnt" >&2
	echo "busids ${busids[@]}" >&2
	echo "brands ${brands[@]}" >&2
	echo "powers ${powers[@]}" >&2
	echo "temps  ${temps[@]}" >&2
	echo "jtemps ${jtemps[@]}" >&2
	echo "mtemps ${mtemps[@]}" >&2
	echo "fans   ${fans[@]}" >&2
	echo "loads  ${loads[@]}" >&2
fi


function array_to_json() {
	local -n arr=$1
	# jq variant
	#printf '%s\n' "${arr[@]}" | jq --raw-input . | jq --slurp -c . ; return
	# bash variant
	local output=
	for(( i = 0; i < ${#arr[@]}; i++ )); do
		output+="${output:+,}\"${arr[i]}\""
	done
	echo "[$output]"
}


# do not send if all values are zero
[[ "${loads[@]}" =~ [1-9] ]] && load=$(jq -c -n --argjson load "`array_to_json loads`" '{$load}') || load="{}"
[[ "${mtemps[@]}" =~ [1-9] ]] && mtemp=$(jq -c -n --argjson mtemp "`array_to_json mtemps`" '{$mtemp}') || mtemp="{}"
[[ "${jtemps[@]}" =~ [1-9] ]] && jtemp=$(jq -c -n --argjson jtemp "`array_to_json jtemps`" '{$jtemp}') || jtemp="{}"

jq -c -n \
--argjson temp "`array_to_json temps`" \
--argjson fan "`array_to_json fans`" \
--argjson power "`array_to_json powers`" \
--argjson busids "`array_to_json busids`" \
--argjson brand "`array_to_json brands`" \
--argjson load "$load" \
--argjson jtemp "$jtemp" \
--argjson mtemp "$mtemp" \
'{$temp, $fan, $power, $busids, $brand} + $load + $mtemp + $jtemp'

exit
