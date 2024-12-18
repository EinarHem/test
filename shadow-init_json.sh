#!/bin/sh
# shadow-init_json.sh
# this script is started by the docker-compose.yml file.
# it will set up everything needed to create a shadow database of brreg.no 
# and keep it updated by monitoring brreg.no for changes 
# Maintanter terchris Terje Christensen
# the solution consists of two containers. One is a standard postgres container, the other is a node container that does all the work.
# The shadow-init_json.sh replaces the shadow-init.sh script. this version uses json as imput and not excel file
# files used to set status of the installation
INITIATEDDBFILE=/usr/src/app/database_initiated.txt
GITHUBDIR=/usr/src/app/shadow-brreg
DOWNLOADDIR=/usr/src/app/download
BRREGENHETERJSONCOMPRESSEDFILE=enheter_alle.json.gz
BRREGENHETERJSONFILE=enheter_alle.json
BRREGENHETERJSONNOPIPEFILE=enheter_alle_nopipe.json
BRREGENHETERCSVFILE=enheter_alle.csv
BRREGTABLEDEFINITIONFILE=brreg_enheter_alle-table_definition.sql
CRONJOBSFILE=app/shadow/cronjobs.txt
BRREGENHETERTABLENAME=brreg_enheter_alle
INITDBSCRIPT=initdb.js
JSON2CSVCONFIGFILE=json2csv-config.json
echo "shadow-init.sh starting. This is the variables used:"
echo "INITIATEDDBFILE=$INITIATEDDBFILE"
echo "GITHUBDIR=$GITHUBDIR"
echo "DOWNLOADDIR=$DOWNLOADDIR"
echo "BRREGENHETERJSONCOMPRESSEDFILE=$BRREGENHETERJSONCOMPRESSEDFILE"
echo "BRREGENHETERJSONFILE=$BRREGENHETERJSONFILE"
echo "BRREGENHETERJSONNOPIPEFILE=$BRREGENHETERJSONNOPIPEFILE"
echo "BRREGENHETERCSVFILE=$BRREGENHETERCSVFILE"
echo "BRREGTABLEDEFINITIONFILE=$BRREGTABLEDEFINITIONFILE"
echo "CRONJOBSFILE=$CRONJOBSFILE"
echo "BRREGENHETERTABLENAME=$BRREGENHETERTABLENAME"
echo "INITDBSCRIPT=$INITDBSCRIPT"
echo "JSON2CSVCONFIGFILE=$JSON2CSVCONFIGFILE"
echo "DATABASE_HOST=$DATABASE_HOST"
echo "DATABASE_PORT=$DATABASE_PORT"
echo "DATABASE_USER=$DATABASE_USER"
echo "DATABASE_PASSWORD=$DATABASE_PASSWORD"
echo "DATABASE_NAME=$DATABASE_NAME"
echo "1. Install git and cron"
apk add git apk-cron postgresql-client 
echo "1.a. Install json2csv client"
npm install -g @json2csv/cli@6.1.3
echo "1.b. Install json2csv transforms"
npm install -g @json2csv/transforms@6.1.3
echo "2. Install typescript"
npm install -g typescript
echo "2.5. delete the shadow app if it exists"
rm -rf "$GITHUBDIR"
echo "3. Clone the shadow app from github to $GITHUBDIR"
git clone --no-hardlinks https://github.com/terchris/shadow-brreg "$GITHUBDIR"
echo "4. Make cron scripts executable"
chmod +x "$GITHUBDIR/app/shadow/shadow-cronjob.sh"
echo "5. Set up and compile the shadow app"
cd "$GITHUBDIR/app/shadow"
echo "6. yarn install"
yarn install
echo "7. yarn build"
yarn build
echo "8. Check if database is initiated "
if [ ! -f "$INITIATEDDBFILE" ]; then 
    echo "8a. Database is not initiated"
    echo "8b. create download folder $DOWNLOADDIR"
    mkdir "$DOWNLOADDIR"
    echo "8c. download compressed json file enheter_alle.json.gz from brreg.no to $DOWNLOADDIR/$BRREGENHETERJSONCOMPRESSEDFILE"
    wget -O "$DOWNLOADDIR/$BRREGENHETERJSONCOMPRESSEDFILE" 'https://data.brreg.no/enhetsregisteret/api/enheter/lastned'
    echo "8d. uncompress the file $DOWNLOADDIR/$BRREGENHETERJSONCOMPRESSEDFILE to $DOWNLOADDIR/$BRREGENHETERJSONFILE"
    gunzip "$DOWNLOADDIR/$BRREGENHETERJSONCOMPRESSEDFILE"
    echo "8e. remove the pipe character from the file $DOWNLOADDIR/$BRREGENHETERJSONFILE and save it as $DOWNLOADDIR/$BRREGENHETERJSONNOPIPEFILE"
    awk '{gsub(/\|/,"")}1' "$DOWNLOADDIR/$BRREGENHETERJSONFILE" > "$DOWNLOADDIR/$BRREGENHETERJSONNOPIPEFILE"
    echo "8f. TAKES TIME to convert json file $BRREGENHETERJSONNOPIPEFILE to csv format and name it $BRREGENHETERCSVFILE"
    start=`date +%s`
    json2csv -i "$DOWNLOADDIR/$BRREGENHETERJSONNOPIPEFILE" -o "$DOWNLOADDIR/$BRREGENHETERCSVFILE" -d "|" -c "$JSON2CSVCONFIGFILE"
    end=`date +%s`
    echo You wasted  `expr $end - $start` seconds of your life converting the file
    echo "8g. wait until the databse in the other container is ready" 
    until pg_isready -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_USER"
    do
        echo "... waiting for database to be ready ..."
        sleep 1
    done
    sleep 2
    echo "8h. Database is ready"
    echo "8i. create the database: $DATABASE_NAME"
    PGPASSWORD="$DATABASE_PASSWORD" psql -h "$DATABASE_HOST" -p "$DATABASE_PORT" --user="$DATABASE_USER" -c "CREATE DATABASE $DATABASE_NAME OWNER $DATABASE_USER;"
    echo "8j. create the table $BRREGENHETERTABLENAME using definition in $BRREGTABLEDEFINITIONFILE"
    PGPASSWORD="$DATABASE_PASSWORD" psql -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_USER" -d "$DATABASE_NAME" -f "$GITHUBDIR"/"$BRREGTABLEDEFINITIONFILE"
    echo "8k. Import the csv file $BRREGENHETERCSVFILE to the database"
    PGPASSWORD="$DATABASE_PASSWORD" psql -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_USER" -d "$DATABASE_NAME" -c "\COPY $BRREGENHETERTABLENAME FROM '$DOWNLOADDIR/$BRREGENHETERCSVFILE' WITH DELIMITER '|' CSV HEADER;"
    echo "8l. Create a file $INITIATEDDBFILE to indicate that the database is initiated"
    date > "$INITIATEDDBFILE"
    echo "8m. Delete the downloaded files: $BRREGENHETERJSONFILE and $BRREGENHETERCSVFILE"
    rm "$DOWNLOADDIR/$BRREGENHETERJSONFILE"
    rm "$DOWNLOADDIR/$BRREGENHETERCSVFILE"
    rm "$DOWNLOADDIR/$BRREGENHETERJSONNOPIPEFILE"
    echo "8n. Add the number of records imported to the $INITIATEDDBFILE file"
    PGPASSWORD="$DATABASE_PASSWORD" psql -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_USER" -d "$DATABASE_NAME" -c "SELECT COUNT(*) FROM $BRREGENHETERTABLENAME;" >> "$INITIATEDDBFILE"
    echo "8o. Display the $INITIATEDDBFILE file (showing number of records imported))"
    cat "$INITIATEDDBFILE"
    echo "8p. Add and initiate tables used by the node app to keep the database updated"
    node "$GITHUBDIR/app/shadow/dist/$INITDBSCRIPT"
fi
echo "9. Add the job to cron"
/usr/bin/crontab "$GITHUBDIR/$CRONJOBSFILE"
# you must set the absolute path to the script in the cronjob file
echo "10. Start cron and wait for jobs to run"
echo "======================================"
/usr/sbin/crond -f -l 8
# to list cron jobs: crontab -l
echo "shadow-setup.sh done"
