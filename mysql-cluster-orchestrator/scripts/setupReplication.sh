#!/bin/bash

CONF_FILE="/etc/my.cnf"

DB_MASTER=$1
MYSQL_ADMIN_USER=$2
MYSQL_ADMIN_PASSWORD=$3
DB_REPLICA_USER=$4
DB_REPLICA_PASSWORD=$5

MYSQL=`which mysql`
MYSQLADMIN=`which mysqladmin`
MYSQLREPLICATE=`which mysqlreplicate`

# Set MySQL REPLICATION-MASTER

{ EXTERNAL_IP=$(ip addr show venet0 | awk '/inet / {gsub(/\/.*/,"",$2); print $2}' |  sed -n 2p); INTERNAL_IP=$(ip addr show venet0 | awk '/inet / {gsub(/\/.*/,"",$2); print $2}' |  sed -n 3p); [ -z $INTERNAL_IP ] && INTERNAL_IP=$EXTERNAL_IP ;}

waiting_MYSQL_service() {
        local LOOP_LIMIT=60
                for (( i=0 ; i<${LOOP_LIMIT} ; i++ )); do
                        echo "${i} - alive?..\n"
                        $MYSQLADMIN -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD} ping | grep 'mysqld is alive' > /dev/null 2>&1;
                        [ $? == 0 ] && break;
                        sleep 1
    		done
}

waiting_MYSQL_Master_Service() {
        local LOOP_LIMIT=60
                for (( i=0 ; i<${LOOP_LIMIT} ; i++ )); do
                        logPos=$(mysql -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD} -h ${DB_MASTER}  -e "show master status" -E 2>/dev/null | grep Position | cut -d: -f2 | sed 's/^[ ]*//')
                        echo "$i - logPos - $logPos\n"
                        [ $logPos -ne 0 ] && break;
                        sleep 1
                done
}

set_mysql_variable () {
        local variable=$1
        local new_value=$2
        $MYSQL -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD} -e "SET GLOBAL $variable=$new_value";
}

waiting_MYSQL_service;


if `hostname | grep -q "${DB_MASTER}\-"`
then
	echo "=> Configuring MySQL replicaiton as master ..."
	if [ ! -f /master_repl_set ]; then
    	RAND="$(date +%s | rev | cut -c 1-2)$(echo ${RANDOM})"
		sed -i "s/^server-id.*/server-id = ${RAND}/" ${CONF_FILE}
		/sbin/service mysql restart 2>&1;
		sleep 3
		waiting_MYSQL_service;
		echo "=> Creating a log user ${DB_REPLICA_USER}:${DB_REPLICA_PASSWORD}"
        	$MYSQL -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD} -e "CREATE USER '${DB_REPLICA_USER}'@'%' IDENTIFIED BY '${DB_REPLICA_PASSWORD}'"
        	$MYSQL -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD} -e "GRANT REPLICATION SLAVE ON *.* TO '${DB_REPLICA_USER}'@'%'"
        	echo "=> Done!"
        	touch /master_repl_set
	else
        	echo "=> MySQL replication master already configured, skip"
	fi
else
# Set MySQL REPLICATION - SLAVE
	echo "=> Configuring MySQL replication as slave ..."
	if [ ! -f /slave_repl_set ]; then
		RAND="$(date +%s | rev | cut -c 1-2)$(echo ${RANDOM})"
		echo "=> Setting master connection info on slave"
		sed -i "s/^server-id.*/server-id = ${RAND}/" ${CONF_FILE}
        	set_mysql_variable server_id ${RAND}
        /sbin/service mysql restart 2>&1;
        sleep 3
        waiting_MYSQL_service;
		waiting_MYSQL_Master_Service;

        logPos=$(mysql -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD} -h ${DB_MASTER}  -e "show master status" -E | grep Position | cut -d: -f2 | sed 's/^[ ]*//')
        logFile=$(mysql -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD} -h ${DB_MASTER}  -e "show master status" -E | grep File | cut -d: -f2 | sed 's/^[ ]*//')

        $MYSQL -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD} -e "CHANGE MASTER TO MASTER_HOST='${DB_MASTER}',MASTER_USER='${DB_REPLICA_USER}',MASTER_PASSWORD='${DB_REPLICA_PASSWORD}',MASTER_PORT=3306,MASTER_LOG_FILE='${logFile}',MASTER_LOG_POS=${logPos},MASTER_CONNECT_RETRY=10"
        $MYSQL -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PASSWORD} -e "START SLAVE;"
  
		#$MYSQLREPLICATE --master=${MYSQL_ADMIN_USER}:${MYSQL_ADMIN_PASSWORD}@${DB_MASTER}:3306 --slave=${MYSQL_ADMIN_USER}:${MYSQL_ADMIN_PASSWORD}@${INTERNAL_IP}:3306 --rpl-user=${DB_REPLICA_USER}:${DB_REPLICA_PASSWORD} --start-from-beginning
		echo "=> Done!"
		touch /slave_repl_set
	else
		echo "=> MySQL replicaiton slave already configured, skip"
	fi
fi
