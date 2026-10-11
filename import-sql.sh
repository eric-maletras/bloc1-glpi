#!/usr/bin/env bash
# Import du jeu d'inventaire M2L dans GLPI : 360 PC et leurs composants,
# fournisseurs, devis et factures, et un échantillon d'écrans (branchés aux
# PC), d'imprimantes et de leurs cartouches, de matériel réseau, de logiciels
# installés et de licences. Vérifié sur le schéma de GLPI 12.0.0.
# Aucun nom ni numéro de série ne reprend le matériel que la mission fait
# saisir à la main (MON-*, IMP-ADM-*, IMP-FORM-*, SW-CORE-01, AP-WIFI-*...).
#
#   sudo bash import-sql.sh
#
# L'import AJOUTE ses données à celles déjà présentes, rien n'est vidé :
# - les identifiants des CSV sont décalés au-delà des plus grands id existants
#   (inchangés sur une base vide), et toutes les références suivent ;
# - les listes (statuts, fabricants, types, modèles, systèmes...) sont
#   fusionnées par nom : un « Hewlett-Packard » déjà saisi est réutilisé ;
# - tout passe dans une seule transaction : en cas d'erreur, la base est
#   intacte ;
# - un second lancement est refusé (numéros de série déjà présents).
#
# Variables facultatives :
#   GLPI_FILES  dossier des données de GLPI (détecté : /var/lib/glpi après la
#               sécurisation, sinon /var/www/glpi/files)
#   CSV_BASE    source des CSV et des PDF : URL du dépôt (par défaut) ou
#               dossier local, par exemple un clone du dépôt
set -euo pipefail

# ===== Paramètres =====
DB_HOST="localhost"
DB_NAME="glpi"
DB_USER="root"
DB_PASS=""                     # vide si tu utilises ~/.my.cnf
MYSQL_OPTS="--local-infile=1 --default-character-set=utf8mb4"
WORKDIR="/tmp/glpi_csv_import"
CSV_BASE="${CSV_BASE:-https://raw.githubusercontent.com/eric-maletras/bloc1-glpi/refs/heads/main}"
WEB_USER="www-data"
SQL_FILE="$WORKDIR/import.sql"

# Listes fusionnées par nom avec l'existant
DROPDOWNS="glpi_states glpi_computertypes glpi_computermodels glpi_manufacturers
  glpi_operatingsystems glpi_operatingsystemkernels glpi_devicefirmwaretypes
  glpi_devicememorytypes glpi_suppliertypes glpi_documentcategories
  glpi_monitortypes glpi_monitormodels glpi_printertypes glpi_printermodels
  glpi_networkequipmenttypes glpi_networkequipmentmodels glpi_cartridgeitemtypes
  glpi_softwarecategories glpi_softwarelicensetypes"

# Références simples : table colonne table_visée
FKS="glpi_computers computermodels_id glpi_computermodels
glpi_computers computertypes_id glpi_computertypes
glpi_computers manufacturers_id glpi_manufacturers
glpi_computers states_id glpi_states
glpi_operatingsystemkernelversions operatingsystemkernels_id glpi_operatingsystemkernels
glpi_items_operatingsystems operatingsystems_id glpi_operatingsystems
glpi_items_operatingsystems operatingsystemkernelversions_id glpi_operatingsystemkernelversions
glpi_devicefirmwares manufacturers_id glpi_manufacturers
glpi_devicefirmwares devicefirmwaretypes_id glpi_devicefirmwaretypes
glpi_items_devicefirmwares devicefirmwares_id glpi_devicefirmwares
glpi_devicememories devicememorytypes_id glpi_devicememorytypes
glpi_items_devicememories devicememories_id glpi_devicememories
glpi_deviceprocessors manufacturers_id glpi_manufacturers
glpi_items_deviceprocessors deviceprocessors_id glpi_deviceprocessors
glpi_deviceharddrives manufacturers_id glpi_manufacturers
glpi_items_deviceharddrives deviceharddrives_id glpi_deviceharddrives
glpi_items_devicenetworkcards devicenetworkcards_id glpi_devicenetworkcards
glpi_suppliers suppliertypes_id glpi_suppliertypes
glpi_documents documentcategories_id glpi_documentcategories
glpi_documents_items documents_id glpi_documents
glpi_infocoms suppliers_id glpi_suppliers
glpi_monitors monitormodels_id glpi_monitormodels
glpi_monitors monitortypes_id glpi_monitortypes
glpi_monitors manufacturers_id glpi_manufacturers
glpi_monitors states_id glpi_states
glpi_printers printermodels_id glpi_printermodels
glpi_printers printertypes_id glpi_printertypes
glpi_printers manufacturers_id glpi_manufacturers
glpi_printers states_id glpi_states
glpi_networkequipments networkequipmentmodels_id glpi_networkequipmentmodels
glpi_networkequipments networkequipmenttypes_id glpi_networkequipmenttypes
glpi_networkequipments manufacturers_id glpi_manufacturers
glpi_networkequipments states_id glpi_states
glpi_cartridgeitems cartridgeitemtypes_id glpi_cartridgeitemtypes
glpi_cartridgeitems manufacturers_id glpi_manufacturers
glpi_cartridgeitems_printermodels cartridgeitems_id glpi_cartridgeitems
glpi_cartridgeitems_printermodels printermodels_id glpi_printermodels
glpi_cartridges cartridgeitems_id glpi_cartridgeitems
glpi_cartridges printers_id glpi_printers
glpi_softwares manufacturers_id glpi_manufacturers
glpi_softwares softwarecategories_id glpi_softwarecategories
glpi_softwareversions softwares_id glpi_softwares
glpi_softwareversions states_id glpi_states
glpi_items_softwareversions softwareversions_id glpi_softwareversions
glpi_softwarelicenses softwares_id glpi_softwares
glpi_softwarelicenses softwarelicensetypes_id glpi_softwarelicensetypes
glpi_softwarelicenses softwareversions_id_buy glpi_softwareversions
glpi_softwarelicenses softwareversions_id_use glpi_softwareversions
glpi_items_softwarelicenses softwarelicenses_id glpi_softwarelicenses"

# Références polymorphes : table colonne_itemtype colonne_items_id
POLY="glpi_items_operatingsystems itemtype items_id
glpi_items_devicefirmwares itemtype items_id
glpi_items_disks itemtype items_id
glpi_items_devicememories itemtype items_id
glpi_items_deviceprocessors itemtype items_id
glpi_items_deviceharddrives itemtype items_id
glpi_items_devicenetworkcards itemtype items_id
glpi_networkports itemtype items_id
glpi_infocoms itemtype items_id
glpi_documents_items itemtype items_id
glpi_items_softwareversions itemtype items_id
glpi_items_softwarelicenses itemtype items_id
glpi_assets_assets_peripheralassets itemtype_asset items_id_asset
glpi_assets_assets_peripheralassets itemtype_peripheral items_id_peripheral"
POLY_TYPES="Computer:glpi_computers Supplier:glpi_suppliers Monitor:glpi_monitors"

# Types de matériel auxquels un statut s'applique ($CFG_GLPI['state_types'])
STATE_TYPES="Computer Monitor NetworkEquipment Peripheral Phone Printer
  SoftwareLicense Certificate Enclosure PDU Line Rack SoftwareVersion Cluster
  Contract Appliance DatabaseInstance Cable Unmanaged PassiveDCEquipment"

# Wrapper mysql (sortie simple, variables expensées)
mysql_exec() {
  [[ -n "${DB_PASS}" ]] && export MYSQL_PWD="${DB_PASS}" || true
  mysql -h "$DB_HOST" -u "$DB_USER" $MYSQL_OPTS "$DB_NAME" -e "$1"
}

# Récupère un fichier du dépôt (URL ou dossier local, selon CSV_BASE)
fetch_file() {
  local rel="$1" dst="$2"
  echo ">> Récupération: $rel"
  mkdir -p "$(dirname "$dst")"
  rm -f -- "$dst"

  if [[ -d "$CSV_BASE" ]]; then
    cp -- "$CSV_BASE/$rel" "$dst"
  else
    # Force le rafraîchissement côté proxy/CDN (no-cache + cache-buster)
    if ! wget -q --header='Cache-Control: no-cache' --no-cache -O "$dst" "$CSV_BASE/$rel?nocache=$(date +%s)"; then
      echo "!! Échec du téléchargement: $CSV_BASE/$rel" >&2
      return 1
    fi
  fi

  if [[ ! -s "$dst" ]]; then
    echo "!! Fichier vide: $dst" >&2
    return 1
  fi
  # Un CSV enregistré sous Windows garde ses fins de ligne CRLF
  [[ "$dst" == *.csv ]] && sed -i 's/\r$//' "$dst"
  return 0
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

# true si $1 (mot) est présent dans la liste $2 (séparée par virgules ou espaces)
in_list() {
  local word="$1" list="$2" x
  for x in ${list//,/ }; do
    [[ "$x" == "$word" ]] && return 0
  done
  return 1
}

# Rend une expression SQL CASE ... qui convertit un jeton de date dans @VARNAME
# Jetons acceptés: NOW, NOW-<N>D|M|A, NOW+<N>D|M|A et NOW()-<N>D|M|A  (insensible aux majuscules)
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
  WHEN UPPER(REPLACE(REPLACE(${var},'(',''),')','')) LIKE 'NOW+%'
    THEN
      CASE RIGHT(UPPER(${var}),1)
        WHEN 'D' THEN DATE_ADD(CURDATE(), INTERVAL CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(UPPER(${var}),'+',-1),'D',1) AS SIGNED) DAY)
        WHEN 'M' THEN DATE_ADD(CURDATE(), INTERVAL CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(UPPER(${var}),'+',-1),'M',1) AS SIGNED) MONTH)
        WHEN 'A' THEN DATE_ADD(CURDATE(), INTERVAL CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(UPPER(${var}),'+',-1),'A',1) AS SIGNED) YEAR)
        ELSE NULL
      END
  ELSE
    -- tente un parse de type ISO; si tu mets 'YYYY-MM-DD' ou 'YYYY-MM-DD HH:MM:SS', ça passe
    STR_TO_DATE(${var}, '%Y-%m-%d %H:%i:%s')
END
EOF
}

STAGED=""   # tables chargées en table temporaire imp_<table>

# Écrit dans $SQL_FILE le chargement d'un CSV dans une copie temporaire de la
# table (imp_<table>), avec interprétation des jetons date.
# Usage:
#   stage_csv TABLE FICHIER "col1,col2,..." "datecol1,datecol2,..."
# - Le 4e paramètre est optionnel. S'il est vide, aucune colonne n'est interprétée.
stage_csv() {
  local table="$1"
  local file="$2"
  local columns="$3"          # colonnes dans l'ordre du CSV
  local date_cols="${4-}"     # sous-ensemble de $columns contenant des dates à interpréter

  # Construit la liste de colonnes du LOAD DATA : pour une date on met @col_raw
  local load_list=""            # ex: id, name, @order_date_raw, ...
  local set_parts=()            # ex: order_date = <CASE ...>, ...

  local col
  IFS=',' read -ra cols <<<"$columns"
  for col in "${cols[@]}"; do
    col="${col// /}"  # trim simple
    if [[ -n "$date_cols" ]] && in_list "$col" "$date_cols"; then
      local uvar="@${col}_raw"
      load_list+="${load_list:+, }${uvar}"
      set_parts+=("${col} = $(sql_from_now_token "$uvar")")
    else
      load_list+="${load_list:+, }${col}"
    fi
  done
  # Si la table a date_mod/date_creation ET qu'elles ne sont pas déjà alimentées par le CSV,
  # on les remplit à NOW()
  if has_column "$table" "date_mod" && has_column "$table" "date_creation"; then
    in_list "date_mod" "$columns"  || set_parts+=("date_mod = NOW()")
    in_list "date_creation" "$columns" || set_parts+=("date_creation = NOW()")
  fi

  local set_clause=""
  if ((${#set_parts[@]})); then
    local IFS=', '
    set_clause="SET ${set_parts[*]}"
  fi

  cat >>"$SQL_FILE" <<EOF
CREATE TEMPORARY TABLE \`imp_${table}\` LIKE \`${table}\`;
LOAD DATA LOCAL INFILE '${file}'
  INTO TABLE \`imp_${table}\`
  CHARACTER SET utf8mb4
  FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '\\\\'
  LINES TERMINATED BY '\n'
  IGNORE 1 LINES
  (${load_list})
  ${set_clause};

EOF
  STAGED+=" ${table}"
}

# Recopie une colonne de référence vers ses nouveaux identifiants (en deux
# temps, pour ne jamais heurter une clé unique au passage). Une référence
# vers une ligne absente du jeu est remise à 0.
#   translate_col TABLE COLONNE TABLE_VISEE [CONDITION_SQL]
translate_col() {
  local t="$1" col="$2" ref="$3" cond="${4:-}"
  local and="${cond:+ AND $cond}" sand="${cond:+ AND s.$cond}"
  cat <<EOF
UPDATE \`imp_$t\` SET $col = $col + 1000000000 WHERE $col > 0$and ORDER BY $col DESC;
UPDATE \`imp_$t\` s JOIN imp_map m ON m.tbl = '$ref' AND m.old_id + 1000000000 = s.$col
  SET s.$col = m.new_id WHERE s.$col >= 1000000000$sand;
UPDATE \`imp_$t\` SET $col = 0 WHERE $col >= 1000000000$and;
EOF
}

# Écrit sur la sortie standard le SQL qui verse les tables imp_* dans les
# vraies tables. Arguments : les tables chargées.
emit_merge() {
  local staged=" $* " t col ref pt tcol icol
  is_staged() { [[ "$staged" == *" $1 "* ]]; }

  echo "-- ===== Fusion avec les données existantes ====="
  echo "CREATE TEMPORARY TABLE imp_map (tbl VARCHAR(64) NOT NULL, old_id INT UNSIGNED NOT NULL,"
  echo "  new_id INT UNSIGNED NOT NULL, is_new TINYINT NOT NULL, PRIMARY KEY (tbl, old_id));"

  # Nettoyage : espaces parasites des CSV, itemtype en minuscules, niveau des statuts
  for t in $*; do
    in_list "$t" "$DROPDOWNS" && echo "UPDATE \`imp_$t\` SET name = TRIM(name);"
  done
  while read -r t tcol icol; do
    is_staged "$t" && echo "UPDATE \`imp_$t\` SET $tcol = CONCAT(UPPER(LEFT($tcol, 1)), SUBSTRING($tcol, 2));"
  done <<<"$POLY"
  is_staged glpi_states && echo "UPDATE imp_glpi_states SET completename = TRIM(completename), level = 1 WHERE states_id = 0;"

  # Refus d'un second import
  if is_staged glpi_computers; then
    cat <<'EOF'
DELIMITER //
BEGIN NOT ATOMIC
  IF EXISTS (SELECT 1 FROM glpi_computers c JOIN imp_glpi_computers s
             ON s.serial = c.serial WHERE c.serial <> '') THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Inventaire déjà importé : ces numéros de série sont déjà dans glpi_computers. Rien n''a été modifié.';
  END IF;
END //
DELIMITER ;
EOF
  fi

  echo "START TRANSACTION;"

  # Correspondance ancien id -> nouvel id, table par table
  for t in $*; do
    echo "SET @base = (SELECT COALESCE(MAX(id), 0) FROM \`$t\`);"
    if in_list "$t" "$DROPDOWNS"; then
      echo "INSERT INTO imp_map SELECT '$t', s.id, MIN(d.id), 0 FROM \`imp_$t\` s JOIN \`$t\` d ON d.name = s.name GROUP BY s.id;"
      echo "INSERT INTO imp_map SELECT '$t', s.id, @base + ROW_NUMBER() OVER (ORDER BY s.id), 1 FROM \`imp_$t\` s LEFT JOIN \`$t\` d ON d.name = s.name WHERE d.id IS NULL;"
    else
      # Décalage simple : sur une base vide, les id du CSV sont conservés
      echo "INSERT INTO imp_map SELECT '$t', s.id, @base + s.id, 1 FROM \`imp_$t\` s;"
    fi
  done

  # Les références suivent
  while read -r t col ref; do
    is_staged "$t" && is_staged "$ref" && translate_col "$t" "$col" "$ref"
  done <<<"$FKS"
  while read -r t tcol icol; do
    is_staged "$t" || continue
    for pt in $POLY_TYPES; do
      is_staged "${pt#*:}" && translate_col "$t" "$icol" "${pt#*:}" "$tcol = '${pt%%:*}'"
    done
  done <<<"$POLY"

  # Les lignes prennent leur nouvel id, puis seules les nouvelles sont versées
  for t in $*; do
    echo "UPDATE \`imp_$t\` SET id = id + 1000000000 ORDER BY id DESC;"
    echo "UPDATE \`imp_$t\` s JOIN imp_map m ON m.tbl = '$t' AND m.old_id + 1000000000 = s.id SET s.id = m.new_id;"
    echo "INSERT INTO \`$t\` SELECT s.* FROM \`imp_$t\` s JOIN imp_map m ON m.tbl = '$t' AND m.new_id = s.id AND m.is_new = 1;"
  done

  # Un statut n'est proposé dans les listes que pour les types où il est visible
  if is_staged glpi_states; then
    echo "INSERT INTO glpi_dropdownvisibilities (itemtype, items_id, visible_itemtype, is_visible)"
    echo "  SELECT 'State', m.new_id, v.t, 1 FROM imp_map m JOIN ("
    local first=1
    for pt in $STATE_TYPES; do
      ((first)) && echo "    SELECT '$pt' AS t" || echo "    UNION ALL SELECT '$pt'"
      first=0
    done
    echo "  ) v WHERE m.tbl = 'glpi_states' AND m.is_new = 1;"
  fi

  echo "COMMIT;"
  echo "SELECT tbl AS 'table', SUM(is_new) AS ajoutees, SUM(1 - is_new) AS reprises FROM imp_map GROUP BY tbl;"
}

# Récupère un PDF, l'ajoute au CSV des documents et à la liste à copier
DOCS_CSV="$WORKDIR/glpi_documents.csv"
DOCS_TO_COPY=()
fetch_document() {
  local document="$1"
  local id="$2"
  local category_id="$3"
  local tmp="$WORKDIR/pdf/${document}.pdf"

  fetch_file "pdf/${document}.pdf" "$tmp"

  # Rangement de GLPI : PDF/<2 premiers caractères du SHA1>/<reste>.PDF
  local sha1 filepath
  sha1="$(sha1sum "$tmp" | awk '{print $1}')"
  filepath="PDF/${sha1:0:2}/${sha1:2}.PDF"

  echo "${id},\"${document}\",\"${document}.pdf\",\"${filepath}\",${category_id},application/pdf,${sha1}" >>"$DOCS_CSV"
  DOCS_TO_COPY+=("$tmp|$filepath")
}

# Charge un CSV du dépôt en table temporaire
load_csv() {
  local table="$1"
  fetch_file "csv/${table}.csv" "$WORKDIR/${table}.csv"
  stage_csv "$table" "$WORKDIR/${table}.csv" "${@:2}"
}

main() {
  [[ $EUID -eq 0 ]] || { echo "!! À lancer avec sudo : le script dépose les PDF dans les données de GLPI." >&2; exit 1; }

  if [[ -z "${GLPI_FILES:-}" ]]; then
    if [[ -d /var/lib/glpi/_cache ]]; then GLPI_FILES=/var/lib/glpi; else GLPI_FILES=/var/www/glpi/files; fi
  fi
  [[ -d "$GLPI_FILES/_cache" ]] || { echo "!! Dossier de données de GLPI introuvable : $GLPI_FILES (le préciser avec GLPI_FILES=...)" >&2; exit 1; }
  echo ">> Données de GLPI : $GLPI_FILES"

  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  : >"$SQL_FILE"

  ############################################

  load_csv glpi_states "id, name, completename"
  load_csv glpi_computertypes "id, name"
  load_csv glpi_computermodels "id, name"
  load_csv glpi_manufacturers "id, name"
  load_csv glpi_operatingsystems "id, name, comment"
  load_csv glpi_operatingsystemkernels "id, name"
  load_csv glpi_operatingsystemkernelversions "id, operatingsystemkernels_id, name, comment"
  load_csv glpi_computers "id, name, serial, computermodels_id, computertypes_id, manufacturers_id, states_id, uuid"
  load_csv glpi_items_operatingsystems "id, items_id, itemtype, operatingsystems_id, operatingsystemkernelversions_id"
  load_csv glpi_devicefirmwaretypes "id, name, comment"
  load_csv glpi_devicefirmwares "id, designation, manufacturers_id, version, devicefirmwaretypes_id"
  load_csv glpi_items_devicefirmwares "id, items_id, itemtype, devicefirmwares_id"
  load_csv glpi_items_disks "id, itemtype, items_id, name, device, mountpoint, filesystems_id, totalsize, freesize"
  load_csv glpi_devicememorytypes "id, name"
  load_csv glpi_devicememories "id, designation, frequence, devicememorytypes_id"
  load_csv glpi_items_devicememories "id, items_id, itemtype, devicememories_id, size, busID"
  load_csv glpi_deviceprocessors "id, designation, frequence, manufacturers_id, frequency_default, nbcores_default, nbthreads_default"
  load_csv glpi_items_deviceprocessors "id, items_id, itemtype, deviceprocessors_id, frequency, nbcores, nbthreads"
  load_csv glpi_deviceharddrives "id, designation, interfacetypes_id, manufacturers_id"
  load_csv glpi_items_deviceharddrives "id, items_id, itemtype, deviceharddrives_id, capacity"
  load_csv glpi_devicenetworkcards "id, designation"
  load_csv glpi_items_devicenetworkcards "id, items_id, itemtype, devicenetworkcards_id, mac"
  load_csv glpi_networkports "id, items_id, itemtype, logical_number, name, instantiation_type, mac"
  load_csv glpi_suppliertypes "id, name"
  load_csv glpi_suppliers "id, entities_id, is_recursive, name, suppliertypes_id, registration_number, address, postcode, town, state, country, website, phonenumber, comment, is_deleted, fax, email, is_active, pictures"
  load_csv glpi_documentcategories "id, name, documentcategories_id, completename, level, ancestors_cache"

  # Devis (catégorie 1) et factures (catégorie 2)
  echo "id,name,filename,filepath,documentcategories_id,mime,sha1sum" >"$DOCS_CSV"
  fetch_document devis_grosbill 1 1
  fetch_document devis_ldlc_pro 2 1
  fetch_document devis_materiel.net 3 1
  fetch_document facture_grosbill 4 2
  fetch_document facture_ldlc_pro 5 2
  fetch_document facture_materiel.net 6 2
  stage_csv glpi_documents "$DOCS_CSV" "id, name, filename, filepath, documentcategories_id, mime, sha1sum"

  load_csv glpi_documents_items "id, documents_id, items_id, itemtype"
  load_csv glpi_infocoms \
    "itemtype, items_id, suppliers_id, order_number, bill, value, sink_type, sink_time, sink_coeff, warranty_duration, buy_date, use_date, order_date, delivery_date, warranty_date" \
    "buy_date, use_date, order_date, delivery_date, warranty_date"

  # Échantillon : écrans branchés aux PC
  load_csv glpi_monitortypes "id, name"
  load_csv glpi_monitormodels "id, name"
  load_csv glpi_monitors "id, name, serial, monitormodels_id, monitortypes_id, manufacturers_id, size, have_subd, have_dvi, states_id, comment"
  load_csv glpi_assets_assets_peripheralassets "id, itemtype_asset, items_id_asset, itemtype_peripheral, items_id_peripheral"

  # Échantillon : imprimantes et cartouches
  load_csv glpi_printertypes "id, name"
  load_csv glpi_printermodels "id, name"
  load_csv glpi_printers "id, name, serial, printermodels_id, printertypes_id, manufacturers_id, states_id, last_pages_counter, have_usb, have_ethernet"
  load_csv glpi_cartridgeitemtypes "id, name"
  load_csv glpi_cartridgeitems "id, name, ref, cartridgeitemtypes_id, manufacturers_id, alarm_threshold"
  load_csv glpi_cartridgeitems_printermodels "id, cartridgeitems_id, printermodels_id"
  load_csv glpi_cartridges "id, cartridgeitems_id, printers_id, date_in, date_use, date_out, pages" \
    "date_in, date_use, date_out"

  # Échantillon : matériel réseau
  load_csv glpi_networkequipmenttypes "id, name"
  load_csv glpi_networkequipmentmodels "id, name"
  load_csv glpi_networkequipments "id, name, serial, networkequipmentmodels_id, networkequipmenttypes_id, manufacturers_id, states_id, comment"

  # Échantillon : logiciels installés et licences
  load_csv glpi_softwarecategories "id, name, softwarecategories_id, completename, level"
  load_csv glpi_softwares "id, name, manufacturers_id, softwarecategories_id"
  load_csv glpi_softwareversions "id, softwares_id, name, states_id"
  load_csv glpi_items_softwareversions "id, items_id, itemtype, softwareversions_id, date_install" "date_install"
  load_csv glpi_softwarelicensetypes "id, name"
  load_csv glpi_softwarelicenses "id, softwares_id, name, completename, level, softwarelicensetypes_id, number, serial, softwareversions_id_buy, softwareversions_id_use, expire, comment" \
    "expire"
  load_csv glpi_items_softwarelicenses "id, items_id, itemtype, softwarelicenses_id"

  #######################################################################################

  emit_merge $STAGED >>"$SQL_FILE"

  echo ">> Import dans la base ${DB_NAME}"
  [[ -n "${DB_PASS}" ]] && export MYSQL_PWD="${DB_PASS}" || true
  mysql -h "$DB_HOST" -u "$DB_USER" $MYSQL_OPTS "$DB_NAME" <"$SQL_FILE"

  # Les fichiers des documents, à la place que GLPI leur attend
  local item src filepath
  for item in "${DOCS_TO_COPY[@]}"; do
    src="${item%%|*}"
    filepath="${item#*|}"
    install -d -o "$WEB_USER" -g "$WEB_USER" "$GLPI_FILES/PDF" "$GLPI_FILES/$(dirname "$filepath")"
    install -o "$WEB_USER" -g "$WEB_USER" -m 644 "$src" "$GLPI_FILES/$filepath"
    echo "OK: $(basename "$src") -> $GLPI_FILES/$filepath"
  done

  echo "Import terminé."
}

# Lancé directement : import ; chargé par « source » : fonctions seules
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
