DROP PROCEDURE IF EXISTS `transfer`;
DROP PROCEDURE IF EXISTS `mergeSummaryPages`;
DROP FUNCTION IF EXISTS `fn_intersect_string`;

DELIMITER $$
CREATE DEFINER=`openmrs`@`localhost` FUNCTION `fn_intersect_string`(arg_str1 TEXT, arg_str2 TEXT) RETURNS text CHARSET utf8
  BEGIN
    SET arg_str1 = CONCAT(arg_str1, ",");
    SET @var_result = "";

    WHILE(INSTR(arg_str1, ",") > 0)
    DO
      SET @var_val = SUBSTRING_INDEX(arg_str1, ",", 1);
      SET arg_str1 = SUBSTRING(arg_str1, INSTR(arg_str1, ",") + 1);

      IF(FIND_IN_SET(@var_val, arg_str2) > 0)
      THEN
        SET @var_result = CONCAT(@var_result, @var_val, ",");
      END IF;
    END WHILE;

    RETURN TRIM(BOTH "," FROM @var_result);
  END$$
DELIMITER ;


DELIMITER $$
CREATE DEFINER=`openmrs`@`localhost` PROCEDURE `transfer`()
  BEGIN
    DECLARE t_name TEXT;
    DECLARE t1_columns TEXT;
    DECLARE t2_columns TEXT;
    DECLARE inter_columns TEXT;
    DECLARE inter_columns_insert TEXT;
    DECLARE pri_columns TEXT;
    DECLARE pri_col TEXT;
    DECLARE where_clause TEXT;
    DECLARE provider_column CHAR(20);
    DECLARE n INT DEFAULT 0;
    DECLARE i INT DEFAULT 0;

    DECLARE done INT DEFAULT FALSE;
    DECLARE done_primary_keys INT DEFAULT FALSE;

    -- Retrieving all tables from the backup database excluding liquibase tables, form,location,encounter_type which are already populated by aijar

    DECLARE cursor_i CURSOR FOR SELECT table_name FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'openmrs_backup'  AND table_rows > 0 AND lower(table_name) not like '%liquibase%' AND lower(table_name) not in ('form','location','encounter_type');

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    DROP TEMPORARY TABLE IF EXISTS tb;
    CREATE TEMPORARY TABLE IF NOT EXISTS tb(`name` TEXT);

    -- Loop through all tables of the backup database

    OPEN cursor_i;
    read_loop: LOOP
      -- Working on the current table
      FETCH cursor_i INTO t_name;

      IF done THEN
        LEAVE read_loop;
      END IF;

      SELECT CONCAT('Processing ',t_name,' table') as log;

      -- Get column names for table from the backup database

      SELECT CONCAT('Getting columns of ',t_name,' table from the backup database') as log;

      SELECT GROUP_CONCAT(COLUMN_NAME) INTO t1_columns FROM INFORMATION_SCHEMA.COLUMNS WHERE table_name = t_name AND table_schema = 'openmrs_backup';

      -- Get column names for table from the new database

      SELECT CONCAT('Getting columns of ',t_name,' table from the new database') as log;

      SELECT GROUP_CONCAT(COLUMN_NAME) INTO t2_columns FROM INFORMATION_SCHEMA.COLUMNS WHERE table_name = t_name AND table_schema = 'openmrs';

      -- Get all primary and keys for table from the old database

      SELECT CONCAT('Getting primary keys for  ',t_name,' table from old database') as log;

      SELECT COUNT(*) INTO n FROM INFORMATION_SCHEMA.COLUMNS WHERE table_name = t_name AND table_schema = 'openmrs_backup' AND COLUMN_KEY = 'PRI';

      SET i=0;

      SET where_clause = '';

      SELECT CONCAT('Constructing where clause for table ',t_name,' to join the old database to the new database') as log;

      WHILE i < n DO
        SELECT COLUMN_NAME INTO pri_col FROM INFORMATION_SCHEMA.COLUMNS WHERE table_name = t_name AND table_schema = 'openmrs_backup' AND COLUMN_KEY = 'PRI' LIMIT i,1;
        SET where_clause = CONCAT(where_clause,'openmrs_backup.',t_name,'.',pri_col,' not in (select ',pri_col,' from openmrs.',t_name,') AND ');
        SET i = i + 1;
      END WHILE;

      -- Finding intersecting columns between the old and the new database for table

      -- TODO add columns whose names are known to have changed in new installation yet they have data

      SELECT CONCAT('Finding intersecting columns between the old and the new database for table  ',t_name) as log;

      SELECT fn_intersect_string(t1_columns,t2_columns) INTO inter_columns;

      -- Checking if intersecting columns exists

      IF(inter_columns is not null AND inter_columns <> '') THEN

        -- For encounters, obs, locations_tag_map, replace the value with 2 as this is the default facility ID

        IF t_name in ('encounter','obs','location_tag_map') THEN
          SET inter_columns_insert = REPLACE(inter_columns, 'location_id', '2');
        ELSE
          SET inter_columns_insert = inter_columns;
        END IF;

        -- Creating the data transfer sql from the old database to the new database

        SELECT CONCAT('Creating the data transfer sql statement from the old database to the new database for table  ',t_name) as log;

        SET @q_statment = CONCAT('insert into openmrs.',t_name,'(',inter_columns,') select ',inter_columns_insert,' from openmrs_backup.',t_name,if(where_clause <> '',CONCAT(' where ',SUBSTRING(where_clause, 1, CHAR_LENGTH(where_clause) - 4)),''));

        SELECT CONCAT('Data transfer sql statement from the old database to the new database for table  ',t_name, ' creation complete') as log;

      END IF;

      SELECT CONCAT('Preparing the data transfer sql statement from the old database to the new database for table  ',t_name) as log;

      PREPARE stmt FROM @q_statment;

      SELECT CONCAT('Executing the data transfer sql statement from the old database to the new database for table  ',t_name) as log;

      EXECUTE stmt;

      SELECT CONCAT('Data transfer sql statement from the old database to the new database for table  ',t_name, ' execution complete') as log;

      DEALLOCATE PREPARE stmt;

    END LOOP;
    CLOSE cursor_i;

    SELECT 'Done doing data exports, please wait updating users and providers' as log;

    -- Removed the transfer of locations only updating the main location with the values from the old database
    SELECT 'Updating the location information in the new database with values in the old database' as log;

    UPDATE openmrs.location  AS c1, openmrs_backup.location AS c2 SET c1.location_id = c1.location_id, c1.name= c2.name,c1.description = c2.description,c1.address1 = c2.address1,c1.address2 = c2.address2,c1.city_village = c2.city_village,c1.state_province = c2.state_province,c1.postal_code =c1.postal_code,c1.country = c2.country,c1.latitude = c2.latitude,c1.longitude = c2.longitude ,c1.date_created = c2.date_created,c1.county_district = c2.county_district,c1.retired = c2.retired,c1.date_retired =c1.date_retired,c1.retire_reason = c2.retire_reason WHERE c2.location_id = 1  AND c1.location_id = 2;

    -- add Provider role to all users with Data Entry and Data Manager Role
    -- Removed condition for role as data manager and data entry because some encounters will not have providers
    -- @TODO check if user is has encounters and then add him as normal provider without data entry privileges

    SELECT 'Exporting providers from old database' as log;

    INSERT INTO provider (person_id, creator, date_created, uuid) SELECT person_id, 2, NOW(), UUID() FROM users u WHERE user_id NOT IN (SELECT user_id FROM user_role WHERE role = 'Provider');

    INSERT INTO user_role (user_id, role) SELECT user_id, 'Provider' FROM users u WHERE user_id NOT IN (SELECT user_id FROM user_role WHERE role = 'Provider') AND u.user_id IN (SELECT user_id FROM user_role WHERE (role = 'Data Manager' OR role = 'Data Entry'));

    -- Check to see if the database encounter table has column provider_id
    SELECT COUNT(*) INTO provider_column FROM INFORMATION_SCHEMA.COLUMNS WHERE table_name = 'encounter' AND table_schema = 'openmrs_backup' AND COLUMN_NAME = 'provider_id';
    -- Insert encounter_providers after creating providers
    IF provider_column > 0 THEN
      INSERT INTO openmrs.encounter_provider(encounter_id,provider_id,encounter_role_id,creator,date_created,voided,uuid) select encounter_id,(select openmrs.provider.provider_id from openmrs.provider where person_id = openmrs_backup.encounter.provider_id),2,2,NOW(),0,UUID() from openmrs_backup.encounter;
    END IF;
  END$$
DELIMITER ;

call transfer();

SELECT 'Database export complete' as log;
