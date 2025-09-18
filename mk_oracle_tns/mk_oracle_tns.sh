#!/usr/bin/env bash

# script config file name
SCRIPT_CONFIG_FILE=mk_oracle_tns.cfg

# relative name of logging dir
MK_ORA_LOGDIR_REL=log

# name of logging file
MK_ORA_LOG_FILE=mk_oracle_tns.log

# name of tnsnames.ora file
TNSNAMES_ORA_FILENAME=tnsnames.ora

# script name
SCRIPT_NAME_FILE=$(basename $0)

# script working directory absolute name
SCRIPT_NAME_DIR=$(dirname $0)/

display_usage() {
    cat <<MK-ORA-USAGE

USAGE:
  $SCRIPT_NAME_FILE [OPTIONS]

DESCRIPTION:
  CheckMK agent plugin for monitoring local Oracle databases.

OPTIONS:
  -h, --help            Show this help message and quit

  -l, --log             Activate logging into file $MK_ORA_LOG_FILE

  -d                    Enable Bash debugging

CONFIGURATION:

  The following variables can be used to configure $SCRIPT_NAME_FILE behaviour:

  MK_CONFDIR            Directory containing $SCRIPT_CONFIG_FILE optional 
                        configuration file; if not set,  defaults to script
                        working directory.

  The following variables can be used either in the configuration file $SCRIPT_CONFIG_FILE 
  (takes precedence) or be exported prior to script execution:

  MK_VARDIR             Directory containing logging sub directory for this script,
                        defaults to \$MK_CONFDIR

  ORACLE_HOME           Oracle directory containing 'network/admin/tnsnames.ora' file and 
                        'bin/sqlplus' executable file

  ONLY_SIDS="<sid> ..." Specify which SIDs will be checked.
                        This variable has priority 1.
                        Default is empty.

  SKIP_SIDS="<sid> ..." Specify which SIDs will not be checked.
                        This variable has priority 2.
                        Default is empty.

  MK_ORA_LOGGING        "true | false" same as '-l | --log", manages execution steps
                        logging into $MK_ORA_LOG_FILE


MK-ORA-USAGE
}

MK_ORA_DEBUG=false
MK_ORA_LOGGING=false

# process command line parameters
while test -n "$1"; do
    case "$1" in
        -h | --help)
            display_usage
            exit 0
            ;;

        -d)
            set -xv
            MK_ORA_DEBUG=true
            shift
            ;;

        -l | --log)
            MK_ORA_LOGGING=true
            shift
            ;;

        *)
            shift
            ;;
    esac
done

# print message to STDERR and exit
exit_error() {

    >&2 echo "$1"

    exit 1
}

# local configuration variables
load_config() {

    if [ -z "$MK_CONFDIR" ]; then

        MK_CONFDIR=$SCRIPT_NAME_DIR
    fi

    if [[ ! -d "$MK_CONFDIR" ]]; then

        exit_error "ERROR: \$MK_CONFDIR ('$MK_CONFDIR') is not a directory" 
    fi

    # Source the optional configuration file for this agent plugin
    if [ -e "$MK_CONFDIR/$SCRIPT_CONFIG_FILE" ]; then
        . "$MK_CONFDIR/$SCRIPT_CONFIG_FILE"
    fi

    if [ ! "$ORACLE_HOME" ]; then
        exit_error "ORACLE_HOME not set!"
    fi

}

logging() {
    if $MK_ORA_LOGGING; then
        local log_file=${MK_ORA_LOG_FILE_FULL}
        local criticality=
        local args=
        local header=
        local to_stderr=false

        i=0
        while test -n "$1"; do
            case "$1" in
                -o)
                    criticality="0" # OK, default
                    shift
                    ;;

                -w)
                    criticality="1" # WARNING
                    shift
                    ;;

                -c)
                    criticality="2" # CRITICAL
                    shift
                    ;;

                -u)
                    criticality="3" # UNKNOWN
                    shift
                    ;;

                -e)
                    to_stderr=true  # ERROR
                    shift
                    ;;

                *)
                    args[i]="$1"
                    i=$((i + 1))
                    shift
                    ;;
            esac
        done

        if [ -z "${criticality}" ]; then
            criticality="0"
        fi

        header="$(perl -MPOSIX -le 'print strftime "%F %T", localtime $^T') [${criticality}] ${args[0]}"

        if [ "${#args[@]}" -le 1 ]; then
            echo "$header" >>"$log_file" || exit_error "Unable to append to logfile '$log_file'"
            if [ $to_stderr = true ]; then
                echo "$header" >&2
            fi
        else
            for arg in "${args[@]:1}"; do
                echo "${header} $arg" >>"$log_file" || exit_error "Unable to append to logfile '$log_file'"
                if [ $to_stderr = true ]; then
                    echo "${header} $arg" >&2
                fi
            done
        fi
    fi
}

# check that no users other than root can change the file
only_root_can_modify() {
    permissions=$1
    owner=$2
    group=$3

    group_write_perm=$(echo "$permissions" | cut -c 6)
    other_write_perm=$(echo "$permissions" | cut -c 9)

    if [ "$owner" != "root" ] || [ "$other_write_perm" != "-" ]; then
        return 1
    fi

    [ "$group" = "root" ] || [ "$group_write_perm" = "-" ]
}

# check if command have to be ran under 'sun'
needs_user_switch_before_executing() {
    BINARY_PATH=$1

    [ "$(whoami)" = "root" ] && ! only_root_can_modify "$(stat -c '%A' "$BINARY_PATH")" "$(stat -c '%U' "$BINARY_PATH")" "$(stat -c '%G' "$BINARY_PATH")"
}

# get file owner
get_binary_owner() {
    BINARY_PATH=$1
    stat -c '%U' "${BINARY_PATH}"
}

# check how the executable will be ran
get_binary_execution_mode() {
    BINARY_PATH=$1
    BINARY_USER=$2

    # if the executable belongs to someone besides root, do not execute it as root
    if needs_user_switch_before_executing "$BINARY_PATH"; then
        echo "su ${BINARY_USER} -c"
        return
    fi
    echo "bash -c"
}

# Prepare SQL prefix to be run with each sqplus executable invocation
ora_session_environment() {
    echo -e "SET HEADING OFF\nSET FEEDBACK OFF\nSET MARKUP CSV ON QUOTE OFF"
    echo ' '
}

# skip certail PDBs
skip_sid() {
    local sid="$1"
    if [ "$ONLY_SIDS" ]; then
        [[ " $ONLY_SIDS " != *" $sid "* ]]
        return
    fi

    if [ "$SKIP_SIDS" ]; then
        [[ " $SKIP_SIDS " == *" $sid "* ]]
        return
    fi

    EXCLUDE=EXCLUDE_$sid
    # Handle explicit exclusion of instances but not for +ASM
    if [[ "$EXCLUDE" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
        EXCLUDE=${!EXCLUDE}
        [ "$EXCLUDE" = "ALL" ]
        return
    fi

    false
}


# Execure SQL query
mk_ora_sqlplus() {
    # Executes a SQL query by using sqlplus binary.
    # The query will be piped-in and consumed via cat - so always execute cat at the very beginning of the function
    mk_ora_sqlplus_stdin="$(cat)"
    MK_DB_CONNECT="$1"
    local from_where="$1"
    local print_elapsed_time="$2"
    local start_time=
    local elapsed_time=
    local output=

    read -r -d '' pipe_input <<EOM
WHENEVER SQLERROR CONTINUE
$(ora_session_environment)${mk_ora_sqlplus_stdin}
EOM
    SQLPLUS="$ORACLE_HOME/bin/sqlplus"
    if [ ! -x "${SQLPLUS}" ]; then
        logging -w -e "SQLplus '${SQLPLUS}' not found or ORACLE_HOME '${ORACLE_HOME}' wrong."
        return 1
    fi

    EXECUTION_USER="$(get_binary_owner "$SQLPLUS")"
    EXECUTION_MODE="$(get_binary_execution_mode "$SQLPLUS" "$EXECUTION_USER")"

    pipe_input_quoted=$(echo "$pipe_input" | tr '\n' ';')

    logging "CMD: echo \"$pipe_input_quoted\" | $EXECUTION_MODE \"$SQLPLUS -S $MK_DB_CONNECT\""

    if output=$(echo "$pipe_input" | $EXECUTION_MODE "$SQLPLUS -S $MK_DB_CONNECT" 2>/dev/null); then

        logging "OUT: ${output:0:100}"

        echo "$output"

    else

        output=$(
            echo -e "$output" | grep -v "^ERROR at line" | tr '\n' ' '
        )

        logging -w "ERR: ${output:0:100}"

        echo "${output:0:100}"
    fi
}

read_pdb_status() {

    TNS_ADMIN="$ORACLE_HOME/network/admin/"

    if [[ ! -d "$TNS_ADMIN" ]]; then

        MSG="ERROR: \$TNS_ADMIN ($TNS_ADMIN) is not a directory"

        logging -c "$MSG"

        exit_error "$MSG"
    fi

    TNSNAMES_ORA_FILENAME_FULL="$TNS_ADMIN/$TNSNAMES_ORA_FILENAME"

    if [[ ! -r "$TNSNAMES_ORA_FILENAME_FULL" || ! -f "$TNSNAMES_ORA_FILENAME_FULL" ]]; then

        MSG="ERROR: $TNSNAMES_ORA_FILENAME_FULL is not a file or is not readable"

        logging -w "$MSG"

        exit_error "$MSG"
    fi

    logging "Reading IFILE entries containing $TNSNAMES_ORA_FILENAME from the $TNSNAMES_ORA_FILENAME_FULL file..."

    ALL_PDBS=()

    # Step 1 -- collect IFILE entries from $TNS_ADMIN/tnsnames.ora and extract Service Names (Database names) from IFILEs
    while read IFILE; do

        # look for service names, but print out only those followed by 'SERVICE_NAME' descriptor,
        # that are considered database entries, to distinguish them from listener names
        logging "Found IFILE entry '$IFILE'"
        SERVICES=$(awk  '/^[[:alnum:]_]+[[:space:]]=/ { NETSERV_CAND = $1 } /SERVICE_NAME/ { if (NETSERV_CAND) { print NETSERV_CAND; NETSERV_CAND = ""}  }' "$IFILE" | sort -u)

        if [ -z "$SERVICES" ]; then

            logging -w "No net services found in the IFILE entry $IFILE: $SERVICES"

        else

            for DB in $SERVICES; do
                logging "Found Service '$DB' in $IFILE"

                if skip_sid "$DB"; then
                    logging "Skipping this PDB as per configuration"
                    continue
                fi

                ALL_PDBS+=("$DB")
            done
        fi
    done <<< $(egrep '^IFILE=' "$TNSNAMES_ORA_FILENAME_FULL" | grep "$TNSNAMES_ORA_FILENAME" | awk -F= '{print $2}')

    PDBS_COUNT=${#ALL_PDBS[@]}

    if [ "$PDBS_COUNT" -eq "0" ]; then

        MSG="ERROR: No net services found: $PDBS_COUNT "

        logging -c "$MSG"

        exit_error "$MSG"
    fi

    # Enumerate the collected PDBs
    for i in "${!ALL_PDBS[@]}"; do
        PDB=${ALL_PDBS[$i]}
        logging "[$i] $PDB"
        QUERY="SELECT open_mode FROM v\$pdbs WHERE name = '$PDB';"
        OUT=$(echo $QUERY | mk_ora_sqlplus "/@$PDB")


        if [ "$OUT" == 'READ WRITE' ]; then

            echo "0 \"$PDB\" - Oracle PDB '$PDB' status OK (READ WRITE)"

        elif [[ "$OUT" =~ ERROR ]]; then

            echo "2 \"$PDB\" - Oracle PDB '$PDB' status '$OUT'"

        else 

            if [ "$OUT" == ' ' ]; then
                OUT=unknown
            fi

            echo "1 \"$PDB\" - Oracle PDB '$PDB' status '$OUT'"
        fi
    done
}


main() {

    load_config

    if [ -z "$MK_VARDIR" ]; then

        MK_VARDIR="$MK_CONFDIR"
    fi

    MK_ORA_LOGDIR="$MK_VARDIR/$MK_ORA_LOGDIR_REL"

    MK_ORA_LOG_FILE_FULL="$MK_ORA_LOGDIR/$MK_ORA_LOG_FILE"

    if $MK_ORA_LOGGING; then
        if [ ! -d "$MK_ORA_LOGDIR" ]; then
            mkdir "$MK_ORA_LOGDIR" || exit 1
        fi
    fi

    logging "==========" "Starting: $0"

    logging " " \
            "\$MK_CONFDIR           : $MK_CONFDIR" \
            "\$MK_VARDIR            : $MK_VARDIR" \
            "\$SCRIPT_CONFIG_FILE   : $SCRIPT_CONFIG_FILE" \
            "\$ORACLE_HOME          : $ORACLE_HOME"

    #export ORACLE_HOME

    read_pdb_status
}

[ -z "${MK_SOURCE_ONLY}" ] && main

