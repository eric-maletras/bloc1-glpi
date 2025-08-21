#!/usr/bin/env bash
set -euo pipefail

# ===== Paramètres =====
DB_HOST="localhost"
DB_NAME="glpi"
DB_USER="root"
DB_PASS=""                     # vide si tu utilises ~/.my.cnf
MYSQL_OPTS="--local-infile=1 --default-character-set=utf8mb4"
WORKDIR="/tmp/glpi_csv_import"
rm -rf $WORKDIR
mkdir -p "$WORKDIR"

# Wrapper mysql (sortie simple, variables expensées)
mysql_exec() {
  [[ -n "${DB_PASS}" ]] && export MYSQL_PWD="${DB_PASS}" || true
  mysql -h "$DB_HOST" -u "$DB_USER" $MYSQL_OPTS "$DB_NAME" -e "$1"
}

# Télécharge un CSV via wget (réécrit systématiquement le fichier local)
fetch_csv() {
  local url="$1" dst="$2"
  echo ">> Téléchargement: $url -> $dst"

  # S'assure que le dossier existe et supprime l'ancien fichier le cas échéant
  mkdir -p "$(dirname "$dst")"
  [[ -e "$dst" ]] && rm -f -- "$dst"

  # Force le rafraîchissement côté proxy/CDN (no-cache + cache-buster)
  local sep='?'; [[ "$url" == *\?* ]] && sep='&'
  local url_nc="${url}${sep}nocache=$(date +%s)"

  if ! wget -q --header='Cache-Control: no-cache' --no-cache -O "$dst" "$url_nc"; then
    echo "!! Échec du téléchargement: $url" >&2
    return 1
  fi

  # Contrôle basique
  if [[ ! -s "$dst" ]]; then
    echo "!! Fichier vide après téléchargement: $dst" >&2
    return 1
  fi
}


# Teste si une colonne existe (0 = existe, 1 = n’existe pas)
has_column() {
  local tbl="$1" col="$2"
  local q="SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
           WHERE TABLE_SCHEMA='${DB_NAME}'
             AND TABLE_NAME='${tbl}'
             AND COLUMN_NAME='${col}';"
  local n
  n=$(mysql_exec "$q" | tail -n1 | tr -d '[:space:]')
  [[ "$n" -ge 1 ]]
}

# true si $1 (mot) est présent dans la liste CSV $2
in_csv_list() {
  local word="$1" list="$2"
  IFS=',' read -ra arr <<<"$list"
  for x in "${arr[@]}"; do
    [[ "${x// /}" == "$word" ]] && return 0
  done
  return 1
}

# Rend une expression SQL CASE ... qui convertit un jeton de date dans @VARNAME
# Jetons acceptés: NOW, NOW-<N>D|M|A et NOW()-<N>D|M|A  (insensible aux majuscules)
sql_from_now_token() {
  local var="$1"     # ex: @order_date_raw
  cat <<EOF
CASE
  WHEN ${var} IS NULL OR ${var}='' OR UPPER(${var})='NULL'
    THEN NULL
  WHEN UPPER(REPLACE(REPLACE(${var},'(',''),')',''))='NOW'
    THEN NOW()
  WHEN UPPER(REPLACE(REPLACE(${var},'(',''),')','')) LIKE 'NOW-%'
    THEN
      CASE RIGHT(UPPER(REPLACE(REPLACE(${var},'(',''),')','')),1)
        WHEN 'D' THEN DATE_SUB(CURDATE(), INTERVAL CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(UPPER(REPLACE(REPLACE(${var},'(',''),')','')),'-',-1),'D',1) AS SIGNED) DAY)
        WHEN 'M' THEN DATE_SUB(CURDATE(), INTERVAL CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(UPPER(REPLACE(REPLACE(${var},'(',''),')','')),'-',-1),'M',1) AS SIGNED) MONTH)
        WHEN 'A' THEN DATE_SUB(CURDATE(), INTERVAL CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(UPPER(REPLACE(REPLACE(${var},'(',''),')','')),'-',-1),'A',1) AS SIGNED) YEAR)
        ELSE NULL
      END
  ELSE
    -- tente un parse de type ISO; si tu mets 'YYYY-MM-DD' ou 'YYYY-MM-DD HH:MM:SS', ça passe
    STR_TO_DATE(${var}, '%Y-%m-%d %H:%i:%s')
END
EOF
}


# Charge un CSV (TRUNCATE + LOAD DATA), avec interprétation des jetons date.
# Usage:
#   load_csv TABLE URL "col1,col2,..." "datecol1,datecol2,..."
# - Le 4e paramètre est optionnel. S'il est vide, aucune colonne n'est interprétée.
load_csv() {
  local table="$1"
  local url="$2"
  local columns="$3"          # colonnes dans l'ordre du CSV
  local date_cols="${4-}"     # sous-ensemble de $columns contenant des dates à interpréter
  local tmp="$WORKDIR/${table}.csv"

  fetch_csv "$url" "$tmp"

  # Construit la liste de colonnes du LOAD DATA : pour une date on met @col_raw
  local load_list=""            # ex: id, name, @order_date_raw, ...
  local set_parts=()            # ex: order_date = <CASE ...>, ...

  IFS=',' read -ra cols <<<"$columns"
  for col in "${cols[@]}"; do
    col="${col// /}"  # trim simple
    if [[ -n "$date_cols" ]] && in_csv_list "$col" "$date_cols"; then
      local uvar="@${col}_raw"
      load_list+="${load_list:+, }${uvar}"
      # ajoute l'expression SET pour cette colonne
      local expr
      expr="$(sql_from_now_token "$uvar")"
      set_parts+=("${col} = ${expr}")
    else
      load_list+="${load_list:+, }${col}"
    fi
  done
  # Si la table a date_mod/date_creation ET qu'elles ne sont pas déjà alimentées par le CSV,
  # on les remplit à NOW()
  if has_column "$table" "date_mod" && has_column "$table" "date_creation"; then
    in_csv_list "date_mod" "$columns"  || set_parts+=("date_mod = NOW()")
    in_csv_list "date_creation" "$columns" || set_parts+=("date_creation = NOW()")
  fi

  local set_clause=""
  if ((${#set_parts[@]})); then
    local IFS=', '
    set_clause="SET ${set_parts[*]}"
  fi

  echo ">> TRUNCATE ${table}"
  mysql_exec "SET FOREIGN_KEY_CHECKS=0; TRUNCATE \`${table}\`; SET FOREIGN_KEY_CHECKS=1;"

  echo ">> LOAD DATA -> ${table}"
  mysql_exec "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
    LOAD DATA LOCAL INFILE '${tmp}'
    INTO TABLE \`${table}\`
    CHARACTER SET utf8mb4
    FIELDS TERMINATED BY ',' ENCLOSED BY '\"' ESCAPED BY '\\\\'
    LINES TERMINATED BY '\n'
    IGNORE 1 LINES
    (${load_list})
    ${set_clause};"

  echo "OK: ${table} importée."
}

load_document(){
  local document="$1"
  local id="$2"
  local category_id="$3"

  local url="https://github.com/eric-maletras/bloc1-glpi/raw/main/pdf/$1.pdf"
  local tmp="$WORKDIR/${document}.pdf"

  rm -f  "$tmp"
  fetch_csv "$url" "$tmp"

  local NOW_TS="$(date '+%Y-%m-%d %H:%M:%S')"
#  local extra_set="SET date_mod='${NOW_TS}', date_creation='${NOW_TS}'"

  local SHA1="$(sha1sum $tmp | awk '{print $1}')"
  local PREFIX="${SHA1:0:2}"

  rm -rf "/var/www/glpi/files/PDF/$PREFIX"
  mkdir "/var/www/glpi/files/PDF/$PREFIX"
  local filepath="PDF/$PREFIX/$document.pdf"

  mv "$tmp" "/var/www/glpi/files/$filepath"

  mysql_exec "
    INSERT INTO glpi_documents
      (entities_id, is_recursive, name, filename, filepath,documentcategories_id,mime,date_mod,sha1sum,date_creation)
    VALUES
      (0, 0,'${document}','${document}.pdf','${filepath}',${category_id},'application/pdf','${NOW_TS}','${SHA1}','${NOW_TS}');
     "

  echo "OK: ${document} -> ${filepath}"
  echo "SHA1: ${SHA1}"

} #load_document

############################################

# 1) glpi_states (pas de dates dans le CSV -> la fonction détecte que la table n’a pas date_mod/date_creation)
echo glpi_states
load_csv \
  "glpi_states" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_states.csv" \
  "id, name, completename"

# 2) glpi_computertypes (CSV: id,name ; la table a date_mod/date_creation -> auto-ajout)
echo glpi_computertypes
load_csv \
  "glpi_computertypes" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_computertypes.csv" \
  "id, name"

# 3) glpi_computermodels (CSV: id,name ; idem, dates auto-ajoutées)
echo glpi_computermodels
load_csv \
  "glpi_computermodels" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_computermodels.csv" \
  "id, name"

# 4) glpi_manufacturers (id,name ; dates ajoutées automatiquement si colonnes présentes)

load_csv \
  "glpi_manufacturers" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_manufacturers.csv" \
  "id, name"

load_csv \
  "glpi_operatingsystems" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_operatingsystems.csv" \
  "id, name, comment"

#glpi_operatingsystemkernels
load_csv \
  "glpi_operatingsystemkernels" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_operatingsystemkernels.csv" \
  "id, name"


#glpi_operatingsystemkernelversions
load_csv \
  "glpi_operatingsystemkernelversions" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_operatingsystemkernelversions.csv" \
  "id, operatingsystemkernels_id, name, comment"

#glpi_computers
load_csv \
  "glpi_computers" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_computers.csv" \
  "id,NAME,serial,computermodels_ID,computerTypes_ID,manufacturers_ID,States_ID,UUID"

# glpi_items_operatingsystems
load_csv \
  "glpi_items_operatingsystems" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_items_operatingsystems.csv" \
  "id,items_id,itemtype,operatingsystems_id,operatingsystemkernelversions_id"

# glpi_devicefirmwaretypes
load_csv \
  "glpi_devicefirmwaretypes" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_devicefirmwaretypes.csv" \
  "id, name, comment"

# glpi_devicefirmwares
load_csv \
  "glpi_devicefirmwares" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_devicefirmwares.csv" \
  "id, designation, manufacturers_id, version, devicefirmwaretypes_id"

# glpi_items_devicefirmwares
load_csv \
  "glpi_items_devicefirmwares" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_items_devicefirmwares.csv" \
  "id, items_id, itemtype, devicefirmwares_id"

# glpi_items_disks
load_csv \
  "glpi_items_disks" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_items_disks.csv" \
  "id, itemtype, items_id, name, device, mountpoint, filesystems_id, totalsize, freesize"

# glpi_devicememorytypes
load_csv \
  "glpi_devicememorytypes" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_devicememorytypes.csv" \
  "id, name"


# glpi_devicememories
load_csv \
  "glpi_devicememories" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_devicememories.csv" \
  "id, designation, frequence, devicememorytypes_id"

# glpi_items_devicememories
load_csv \
  "glpi_items_devicememories" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_items_devicememories.csv" \
  "id, items_id, itemtype, devicememories_id, size, BusID"

# glpi_deviceprocessors
load_csv \
  "glpi_deviceprocessors" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_deviceprocessors.csv" \
  "id, designation, frequence , manufacturers_id, frequency_default, nbcores_default, nbthreads_default"

# glpi_items_deviceprocessors
load_csv \
  "glpi_items_deviceprocessors" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_items_deviceprocessors.csv" \
  "id, items_id,itemtype,deviceprocessors_id,frequency,nbcores,nbthreads"

# glpi_deviceharddrives
load_csv \
  "glpi_deviceharddrives" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_deviceharddrives.csv" \
  "id,designation,interfacetypes_id,manufacturers_id"

# glpi_items_deviceharddrives
load_csv \
  "glpi_items_deviceharddrives" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_items_deviceharddrives.csv" \
  "id, items_id, itemtype, deviceharddrives_id, capacity"

# glpi_devicenetworkcards
load_csv \
  "glpi_devicenetworkcards" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_devicenetworkcards.csv" \
  "id, designation"

# glpi_items_devicenetworkcards
load_csv \
  "glpi_items_devicenetworkcards" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_items_devicenetworkcards.csv" \
  "id,items_id, itemtype, devicenetworkcards_id, mac"

# glpi_networkports
load_csv \
  "glpi_networkports" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_networkports.csv" \
  "id, items_id, itemtype, logical_number, name, instantiation_type, mac"

# glpi_suppliertypes
load_csv \
  "glpi_suppliertypes" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_suppliertypes.csv" \
  "id,name"

# glpi_suppliers
load_csv \
  "glpi_suppliers" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_suppliers.csv" \
  "id, entities_id, is_recursive, name, suppliertypes_id, registration_number, address, postcode, town, state, country,website, phonenumber, comment, is_deleted, fax, email,is_active, pictures"

# glpi_documentcategories
load_csv \
  "glpi_documentcategories" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_documentcategories.csv" \
  "id,name,documentcategories_id,completename,level,ancestors_cache"


#######################################################################################

mysql_exec "TRUNCATE glpi_documents;"
rm -rf /var/www/glpi/files/PDF/*

# document devis grosbill
load_document \
  "devis_grosbill" \
  1 \
  1

# devis_ldlc_pro.pdf
load_document \
  "devis_ldlc_pro" \
  2 \
  1

# devis_materiel.net.pdf
load_document \
  "devis_materiel.net" \
  3 \
  1

# facture_grosbill.pdf
load_document \
  "facture_grosbill" \
  4 \
  2

# facture_ldlc_pro.pdf
load_document \
  "facture_ldlc_pro" \
  5 \
  2

# facture_materiel.net.pdf
load_document \
  "facture_materiel.net" \
  6 \
  2
#glpi_documents_items
load_csv \
  "glpi_documents_items" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_documents_items.csv" \
  "id,documents_id,items_id,itemtype,date"

# glpi_infocoms
load_csv \
  "glpi_infocoms" \
  "https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main/csv/glpi_infocoms.csv" \
  "itemtype,items_id,suppliers_id,order_number,bill,value,sink_type,sink_time,sink_coeff,warranty_duration,buy_date,use_date,order_date,delivery_date,warranty_date" \
  "buy_date,use_date,order_date,delivery_date,warranty_date"

echo "Import terminé."
