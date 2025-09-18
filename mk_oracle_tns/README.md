# CheckMK Script to Monitor Local Oracle PDBs

mk_oracle_tns.sh is a Bash script intended to work with CheckMK.

It monitors local Oracle PDBs (Pluggable Databases) for their states.

It is expected that Oracle Wallet is used for authentication (no cleartext 
usernames or passwords are stored elsewhere in script configuration).

The scripts takes $ORACLE_HOME variable and identifies IFILE entries within tnsnames.ora.

Each IFILE entry is examinated in order to find PDB Net Service entries.

Please note: the script does not look up PDB Net Service entries in the top-level tnsnames.ora
file, but only in the inlcuded files referenced by the IFILE records in the top-level tnsnames.ora

USAGE:
  mk_oracle_tns.sh [OPTIONS]

DESCRIPTION:
  CheckMK agent plugin for monitoring local Oracle databases. 

OPTIONS:
  -h, --help            Shows this help message and quit

  -l, --log             Activate logging into file mk_oracle_tns.log

  -d                    Enable Bash debugging

CONFIGURATION:

  The following variables can be used to configure mk_oracle_tns.sh behaviour:

  MK_CONFDIR            Directory containing mk_oracle_tns.cfg optional
                        configuration file; if not set,  defaults to script 
                        working directory.

  The following variables can be used either in the configuration file mk_oracle_tns.cfg
  (takes precedence) or be exported prior to script execution:

  MK_VARDIR             Directory containing logging sub directory for this script,
                        defaults to $MK_CONFDIR

  ORACLE_HOME           Oracle directory containing 'network/admin/tnsnames.ora' file and
                        'bin/sqlplus' executable file

  ONLY_SIDS="<sid> ..." Specify which SIDs will be checked.
                        This variable has priority 1.
                        Default is empty.

  SKIP_SIDS="<sid> ..." Specify which SIDs will not be checked.
                        This variable has priority 2.
                        Default is empty.

  MK_ORA_LOGGING        "true | false" same as '-l | --log", manages execution steps
                        logging into mk_oracle_tns.log

### Example Output:

# ./mk_oracle_tns.sh
1 "PDB1" - Oracle PDB 'PDB1' status 'READ ONLY'
0 "PDB2" - Oracle PDB 'PDB2' status OK (READ WRITE)
2 "PDB3" - Oracle PDB 'PDB3' status 'ERROR: ORA-12514: TNS:listener does not currently know of service requested in connect descriptor   '

### Known limitations:

This script has only been tested to work under Linux.
