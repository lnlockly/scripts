#!/bin/bash
#   ( РОДИТЕЛЬ | КЛАВИША | НАЗВАНИЕ | ФУНКЦИЯ | ПОРЯДОК | ГРУППА | ОПИСАНИЕ )
# @menu.manifest
# @item( security | 7 | 🔐 SSL Сертификаты (Cloudflare) | show_certificates_menu | 70 | 10 | Получение wildcard сертификатов и раздача на флот. )
#
# certificates.sh - Управление SSL сертификатами через Cloudflare DNS / ACME
#

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1

CERT_CF_CREDENTIALS="${HOME}/.secrets/certbot/cloudflare.ini"

show_certificates_menu() {
    enable_graceful_ctrlc
    while true; do
        clear
        menu_header "🔐 SSL Сертификаты"
        printf_description "Получение wildcard сертификатов и копирование на серверы."

        _cert_show_status

        echo ""
        printf_menu_option "1" "Получить новый сертификат (Cloudflare wildcard)"
        printf_menu_option "2" "Получить сертификат (ACME HTTP-01, без wildcard)"
        printf_menu_option "3" "Обновить все сертификаты (certbot renew)"
        printf_menu_option "4" "Скопировать сертификаты на сервер(а) флота"
        printf_menu_option "5" "Показать все сертификаты"
        printf_menu_option "6" "Управление DNS записями (Cloudflare)"
        echo ""
        printf_menu_option "b" "Назад"
        echo ""

        local choice
        choice=$(safe_read "Выберите действие" "") || break

        case "$choice" in
            1) _cert_generate_cloudflare; wait_for_enter ;;
            2) _cert_generate_acme; wait_for_enter ;;
            3) _cert_renew_all; wait_for_enter ;;
            4) _cert_copy_to_fleet; wait_for_enter ;;
            5) _cert_list_all; wait_for_enter ;;
            6) _dns_manage_menu ;;
            b|B) break ;;
            *) warn "Неверный выбор" ;;
        esac
    done
    disable_graceful_ctrlc
}

# --- Показать статус ---
_cert_show_status() {
    print_separator
    if command -v certbot &>/dev/null; then
        printf_description "certbot: ${C_GREEN}Установлен${C_RESET}"
    else
        printf_description "certbot: ${C_RED}Не установлен${C_RESET}"
    fi

    local cert_count=0
    if [[ -d "/etc/letsencrypt/live" ]]; then
        cert_count=$(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    fi
    printf_description "Сертификатов: ${C_WHITE}${cert_count}${C_RESET}"

    if [[ -f "$CERT_CF_CREDENTIALS" ]]; then
        printf_description "Cloudflare credentials: ${C_GREEN}Настроены${C_RESET}"
    else
        printf_description "Cloudflare credentials: ${C_YELLOW}Не настроены${C_RESET}"
    fi
    print_separator
}

# --- Установка certbot если нет ---
_cert_ensure_certbot() {
    if command -v certbot &>/dev/null; then
        return 0
    fi

    printf_info "certbot не найден, устанавливаю..."
    export DEBIAN_FRONTEND=noninteractive
    if run_cmd apt-get update -qq && run_cmd apt-get install -y -qq certbot python3-certbot-dns-cloudflare; then
        printf_ok "certbot и плагин Cloudflare установлены."
        return 0
    else
        printf_error "Не удалось установить certbot."
        return 1
    fi
}

# --- Извлечь базовый домен ---
_cert_extract_base_domain() {
    echo "$1" | awk -F'.' '{if (NF > 2) {print $(NF-1)"."$NF} else {print $0}}'
}

# --- Валидация Cloudflare API ---
_cert_validate_cloudflare() {
    local cf_key="$1" cf_email="$2"
    local response

    printf_info "Проверяю Cloudflare API..."
    if [[ "$cf_key" =~ [A-Z] ]]; then
        # Это API Token (содержит заглавные буквы)
        response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones \
            --header "Authorization: Bearer ${cf_key}" \
            --header "Content-Type: application/json")
    else
        # Это Global API Key
        response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones \
            --header "X-Auth-Key: ${cf_key}" \
            --header "X-Auth-Email: ${cf_email}" \
            --header "Content-Type: application/json")
    fi

    if echo "$response" | grep -q '"success":true'; then
        printf_ok "Cloudflare API — валидный."
        return 0
    else
        printf_error "Cloudflare API невалидный. Проверь токен/email."
        return 1
    fi
}

# --- Сохранить credentials ---
_cert_save_cloudflare_credentials() {
    local cf_key="$1" cf_email="$2"

    run_cmd mkdir -p "$(dirname "$CERT_CF_CREDENTIALS")"

    if [[ "$cf_key" =~ [A-Z] ]]; then
        cat > "$CERT_CF_CREDENTIALS" <<EOF
dns_cloudflare_api_token = $cf_key
EOF
    else
        cat > "$CERT_CF_CREDENTIALS" <<EOF
dns_cloudflare_email = $cf_email
dns_cloudflare_api_key = $cf_key
EOF
    fi
    chmod 600 "$CERT_CF_CREDENTIALS"
    printf_ok "Credentials сохранены в ${CERT_CF_CREDENTIALS}"
}

# --- 1. Cloudflare wildcard ---
_cert_generate_cloudflare() {
    print_separator
    printf_info "Получение wildcard сертификата через Cloudflare DNS"
    print_separator

    _cert_ensure_certbot || return

    local domain
    domain=$(ask_non_empty "Введи домен (например, example.com): ") || return
    local base_domain
    base_domain=$(_cert_extract_base_domain "$domain")

    # Проверяем, есть ли уже сертификат
    if [[ -d "/etc/letsencrypt/live/${base_domain}" ]]; then
        printf_warning "Сертификат для ${base_domain} уже существует."
        if ! ask_yes_no "Перевыпустить?"; then
            return
        fi
    fi

    local cf_key cf_email

    # Если credentials уже есть, предложить использовать их
    if [[ -f "$CERT_CF_CREDENTIALS" ]]; then
        printf_ok "Найдены сохранённые Cloudflare credentials."
        if ! ask_yes_no "Использовать их?"; then
            cf_key=$(ask_non_empty "Cloudflare API Token или Global API Key: ") || return
            cf_email=$(safe_read "Cloudflare Email (для Global Key, Enter чтобы пропустить): " "")
            _cert_validate_cloudflare "$cf_key" "$cf_email" || return
            _cert_save_cloudflare_credentials "$cf_key" "$cf_email"
        fi
    else
        cf_key=$(ask_non_empty "Cloudflare API Token или Global API Key: ") || return
        cf_email=$(safe_read "Cloudflare Email (для Global Key, Enter чтобы пропустить): " "")
        _cert_validate_cloudflare "$cf_key" "$cf_email" || return
        _cert_save_cloudflare_credentials "$cf_key" "$cf_email"
    fi

    printf_info "Генерирую wildcard сертификат для *.${base_domain} ..."

    if certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CERT_CF_CREDENTIALS" \
        --dns-cloudflare-propagation-seconds 60 \
        -d "${base_domain}" \
        -d "*.${base_domain}" \
        --agree-tos \
        --non-interactive \
        --register-unsafely-without-email \
        --key-type ecdsa \
        --elliptic-curve secp384r1; then
        printf_ok "Wildcard сертификат для *.${base_domain} успешно получен!"
        printf_info "Путь: /etc/letsencrypt/live/${base_domain}/"
    else
        printf_error "Не удалось получить сертификат. Проверь DNS и токен."
    fi
}

# --- 2. ACME HTTP-01 ---
_cert_generate_acme() {
    print_separator
    printf_info "Получение сертификата через ACME HTTP-01 (без wildcard)"
    print_separator

    _cert_ensure_certbot || return

    local domain
    domain=$(ask_non_empty "Введи домен (например, sub.example.com): ") || return

    local email
    email=$(ask_non_empty "Введи email для Let's Encrypt: ") || return

    if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
        printf_warning "Сертификат для ${domain} уже существует."
        if ! ask_yes_no "Перевыпустить?"; then
            return
        fi
    fi

    printf_info "Открываю порт 80 для ACME challenge..."
    ufw allow 80/tcp comment 'ACME challenge' >/dev/null 2>&1

    printf_info "Генерирую сертификат для ${domain}..."

    if certbot certonly \
        --standalone \
        -d "${domain}" \
        --email "${email}" \
        --agree-tos \
        --non-interactive \
        --http-01-port 80 \
        --key-type ecdsa \
        --elliptic-curve secp384r1; then
        printf_ok "Сертификат для ${domain} успешно получен!"
        printf_info "Путь: /etc/letsencrypt/live/${domain}/"
    else
        printf_error "Не удалось получить сертификат. Проверь DNS A-запись и доступность порта 80."
    fi

    ufw delete allow 80/tcp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
}

# --- 3. Обновить все ---
_cert_renew_all() {
    print_separator
    printf_info "Обновление всех сертификатов"
    print_separator

    if ! command -v certbot &>/dev/null; then
        printf_error "certbot не установлен."
        return
    fi

    if certbot renew --no-random-sleep-on-renew; then
        printf_ok "Обновление сертификатов завершено."
    else
        printf_error "Ошибка при обновлении сертификатов."
    fi
}

# --- 4. Копирование сертификатов на флот ---
_cert_copy_to_fleet() {
    print_separator
    printf_info "Копирование сертификатов на серверы флота"
    print_separator

    if [[ ! -d "/etc/letsencrypt/live" ]]; then
        printf_error "Нет сертификатов на этом сервере."
        return
    fi

    # Список доменов с сертификатами
    local domains=()
    local i=1
    while IFS= read -r dir; do
        local dname
        dname=$(basename "$dir")
        [[ "$dname" == "README" ]] && continue
        domains+=("$dname")
        printf_menu_option "$i" "$dname"
        ((i++))
    done < <(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    if [[ ${#domains[@]} -eq 0 ]]; then
        printf_error "Нет сертификатов для копирования."
        return
    fi

    echo ""
    local cert_choice
    cert_choice=$(safe_read "Номер сертификата для копирования: " "") || return

    if [[ -z "$cert_choice" || "$cert_choice" -lt 1 || "$cert_choice" -gt ${#domains[@]} ]] 2>/dev/null; then
        printf_error "Неверный выбор."
        return
    fi

    local selected_domain="${domains[$((cert_choice - 1))]}"
    local cert_dir="/etc/letsencrypt/live/${selected_domain}"

    # Проверяем что файлы есть
    if [[ ! -f "${cert_dir}/fullchain.pem" || ! -f "${cert_dir}/privkey.pem" ]]; then
        printf_error "Файлы сертификата не найдены в ${cert_dir}."
        return
    fi

    printf_ok "Выбран сертификат: ${selected_domain}"

    # Создаём временный архив с реальными файлами (не симлинками)
    local tmp_archive="/tmp/reshala_certs_${selected_domain}.tar.gz"
    tar -czf "$tmp_archive" \
        -C /etc/letsencrypt/live/"${selected_domain}" \
        --dereference \
        fullchain.pem privkey.pem chain.pem cert.pem 2>/dev/null || \
    tar -czf "$tmp_archive" \
        -C /etc/letsencrypt/live/"${selected_domain}" \
        --dereference \
        fullchain.pem privkey.pem 2>/dev/null

    local remote_cert_dir="/etc/letsencrypt/live/${selected_domain}"

    # Выбираем куда копировать
    echo ""
    printf_info "Куда копировать?"
    printf_menu_option "1" "На ВЕСЬ флот"
    printf_menu_option "2" "На ОДИН сервер"
    local scope
    scope=$(safe_read "Выбор (1/2): " "1") || { rm -f "$tmp_archive"; return; }

    if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
        printf_error "База флота пуста."
        rm -f "$tmp_archive"
        return
    fi

    _cert_push_to_server() {
        local name="$1" user="$2" ip="$3" port="$4" key_path="$5"
        printf_warning "--- ${name} (${ip}) ---"

        # Лечим host key если функция доступна (загружена из skynet/keys.sh)
        type _skynet_heal_host_key &>/dev/null && _skynet_heal_host_key "$ip" "$port"

        # Копируем архив (-o BatchMode=yes чтобы не жрал stdin)
        if ! scp -q -P "$port" -i "$key_path" -o StrictHostKeyChecking=no -o BatchMode=yes "$tmp_archive" "${user}@${ip}:/tmp/reshala_certs.tar.gz"; then
            printf_error "Не удалось скопировать на ${name}."
            return 1
        fi

        # Распаковываем на сервере. -n чтобы ssh не съедал stdin цикла while read
        local unpack_cmd="mkdir -p ${remote_cert_dir} && tar -xzf /tmp/reshala_certs.tar.gz -C ${remote_cert_dir} && chmod 600 ${remote_cert_dir}/privkey.pem && rm -f /tmp/reshala_certs.tar.gz"
        if [[ "$user" == "root" ]]; then
            ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$key_path" -p "$port" "${user}@${ip}" "$unpack_cmd"
        else
            ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$key_path" -p "$port" "${user}@${ip}" "sudo bash -c '${unpack_cmd}'"
        fi

        if [[ $? -eq 0 ]]; then
            printf_ok "Сертификат скопирован на ${name}."
        else
            printf_error "Ошибка распаковки на ${name}."
        fi
    }

    if [[ "$scope" == "2" ]]; then
        # На один сервер
        local servers=()
        local idx=1
        echo ""
        printf_info "Доступные серверы:"
        while IFS='|' read -r name user ip port key_path _rest; do
            servers+=("$name|$user|$ip|$port|$key_path")
            printf "   [%d] %s (%s@%s:%s)\n" "$idx" "$name" "$user" "$ip" "$port"
            ((idx++))
        done < "$FLEET_DATABASE_FILE"

        local s_choice
        s_choice=$(safe_read "Номер сервера: " "") || { rm -f "$tmp_archive"; return; }
        if [[ -n "${servers[$((s_choice - 1))]:-}" ]]; then
            IFS='|' read -r name user ip port key_path <<< "${servers[$((s_choice - 1))]}"
            _cert_push_to_server "$name" "$user" "$ip" "$port" "$key_path"
        else
            printf_error "Неверный выбор."
        fi
    else
        # На весь флот
        printf_warning "Копирую сертификат '${selected_domain}' на ВЕСЬ флот..."
        if ask_yes_no "Начать?" "n"; then
            while IFS='|' read -r name user ip port key_path _rest; do
                _cert_push_to_server "$name" "$user" "$ip" "$port" "$key_path"
            done < "$FLEET_DATABASE_FILE"
            printf_ok "Копирование завершено."
        fi
    fi

    rm -f "$tmp_archive"
}

# --- 5. Список всех сертификатов ---
_cert_list_all() {
    print_separator
    printf_info "Установленные сертификаты"
    print_separator

    if ! command -v certbot &>/dev/null; then
        printf_error "certbot не установлен."
        return
    fi

    certbot certificates 2>/dev/null || printf_warning "Нет сертификатов."
}

# ============================================================
#  DNS MANAGEMENT (Cloudflare API)
# ============================================================

# Загрузить CF credentials из файла certbot
_dns_load_cf_creds() {
    CF_KEY="" ; CF_EMAIL=""
    if [[ ! -f "$CERT_CF_CREDENTIALS" ]]; then
        return 1
    fi
    # Пробуем token
    CF_KEY=$(grep -oP '(?<=dns_cloudflare_api_token\s=\s).*' "$CERT_CF_CREDENTIALS" 2>/dev/null | tr -d ' ')
    if [[ -z "$CF_KEY" ]]; then
        CF_KEY=$(grep -oP '(?<=dns_cloudflare_api_key\s=\s).*' "$CERT_CF_CREDENTIALS" 2>/dev/null | tr -d ' ')
        CF_EMAIL=$(grep -oP '(?<=dns_cloudflare_email\s=\s).*' "$CERT_CF_CREDENTIALS" 2>/dev/null | tr -d ' ')
    fi
    [[ -n "$CF_KEY" ]]
}

# Универсальный curl к Cloudflare API
_dns_cf_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local -a headers=( --header "Content-Type: application/json" )

    if [[ "$CF_KEY" =~ [A-Z] ]]; then
        headers+=( --header "Authorization: Bearer ${CF_KEY}" )
    else
        headers+=( --header "X-Auth-Key: ${CF_KEY}" --header "X-Auth-Email: ${CF_EMAIL}" )
    fi

    if [[ -n "$data" ]]; then
        curl --silent --request "$method" --url "https://api.cloudflare.com/client/v4${endpoint}" "${headers[@]}" --data "$data"
    else
        curl --silent --request "$method" --url "https://api.cloudflare.com/client/v4${endpoint}" "${headers[@]}"
    fi
}

# Получить zone_id по домену
_dns_get_zone_id() {
    local domain="$1"
    local resp
    resp=$(_dns_cf_api GET "/zones?name=${domain}&status=active")
    echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Подменю DNS
_dns_manage_menu() {
    # Загружаем credentials
    if ! _dns_load_cf_creds; then
        printf_error "Cloudflare credentials не найдены. Сначала получи сертификат (пункт 1) или введи данные вручную."
        local cf_key cf_email
        cf_key=$(ask_non_empty "Cloudflare API Token или Global API Key: ") || return
        cf_email=$(safe_read "Cloudflare Email (для Global Key, Enter чтобы пропустить): " "")
        _cert_validate_cloudflare "$cf_key" "$cf_email" || return
        _cert_save_cloudflare_credentials "$cf_key" "$cf_email"
        _dns_load_cf_creds || { printf_error "Не удалось загрузить credentials."; return; }
    fi

    while true; do
        clear
        menu_header "🌐 DNS записи (Cloudflare)"
        printf_description "Добавление и просмотр DNS A-записей."
        echo ""
        printf_menu_option "1" "Добавить A-запись"
        printf_menu_option "2" "Показать A-записи домена"
        printf_menu_option "3" "Удалить A-запись"
        printf_menu_option "4" "Массово добавить IP из флота"
        echo ""
        printf_menu_option "b" "Назад"
        echo ""

        local choice
        choice=$(safe_read "Выберите действие" "") || break
        case "$choice" in
            1) _dns_add_a_record; wait_for_enter ;;
            2) _dns_list_a_records; wait_for_enter ;;
            3) _dns_delete_a_record; wait_for_enter ;;
            4) _dns_add_fleet_ips; wait_for_enter ;;
            b|B) break ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# --- 1. Добавить A-запись ---
_dns_add_a_record() {
    print_separator
    printf_info "Добавление DNS A-записи"
    print_separator

    local domain
    domain=$(ask_non_empty "Базовый домен (например, example.com): ") || return

    local zone_id
    zone_id=$(_dns_get_zone_id "$domain")
    if [[ -z "$zone_id" ]]; then
        printf_error "Зона для '${domain}' не найдена в Cloudflare."
        return
    fi
    printf_ok "Зона найдена: ${domain} (${zone_id})"

    local subdomain
    subdomain=$(safe_read "Поддомен (Enter = корень ${domain}): " "")

    local full_name
    if [[ -n "$subdomain" ]]; then
        full_name="${subdomain}.${domain}"
    else
        full_name="${domain}"
    fi

    local ip
    ip=$(ask_non_empty "IP адрес: ") || return

    local proxied="false"
    if ask_yes_no "Проксировать через Cloudflare (оранжевое облако)?" "n"; then
        proxied="true"
    fi

    printf_info "Создаю A-запись: ${full_name} -> ${ip} (proxy: ${proxied})..."

    local resp
    resp=$(_dns_cf_api POST "/zones/${zone_id}/dns_records" \
        "{\"type\":\"A\",\"name\":\"${full_name}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":${proxied}}")

    if echo "$resp" | grep -q '"success":true'; then
        printf_ok "A-запись создана: ${full_name} -> ${ip}"
    else
        local err_msg
        err_msg=$(echo "$resp" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        printf_error "Ошибка: ${err_msg:-неизвестная ошибка}"
    fi
}

# --- 2. Показать A-записи ---
_dns_list_a_records() {
    print_separator
    printf_info "Просмотр A-записей"
    print_separator

    local domain
    domain=$(ask_non_empty "Базовый домен (например, example.com): ") || return

    local zone_id
    zone_id=$(_dns_get_zone_id "$domain")
    if [[ -z "$zone_id" ]]; then
        printf_error "Зона для '${domain}' не найдена."
        return
    fi

    local resp
    resp=$(_dns_cf_api GET "/zones/${zone_id}/dns_records?type=A&per_page=100")

    if ! echo "$resp" | grep -q '"success":true'; then
        printf_error "Не удалось получить записи."
        return
    fi

    local count
    count=$(echo "$resp" | grep -o '"type":"A"' | wc -l | tr -d ' ')
    printf_ok "Найдено A-записей: ${count}"
    echo ""

    # Парсим и выводим
    echo "$resp" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('result', []):
    proxy = '☁️ ' if r.get('proxied') else '  '
    print(f'  {proxy} {r[\"name\"]:40s} -> {r[\"content\"]:16s}  (id: {r[\"id\"][:8]}...)')
" 2>/dev/null || {
        # Фоллбек без python
        echo "$resp" | grep -oP '"name":"[^"]*"|"content":"[^"]*"|"proxied":(true|false)' | paste - - - | while read -r line; do
            local name content proxied_val
            name=$(echo "$line" | grep -oP '"name":"[^"]*"' | cut -d'"' -f4)
            content=$(echo "$line" | grep -oP '"content":"[^"]*"' | cut -d'"' -f4)
            proxied_val=$(echo "$line" | grep -oP '"proxied":\w+' | cut -d: -f2)
            local icon="  "; [[ "$proxied_val" == "true" ]] && icon="☁️ "
            printf "  %s %-40s -> %s\n" "$icon" "$name" "$content"
        done
    }
}

# --- 3. Удалить A-запись ---
_dns_delete_a_record() {
    print_separator
    printf_info "Удаление DNS A-записи"
    print_separator

    local domain
    domain=$(ask_non_empty "Базовый домен (например, example.com): ") || return

    local zone_id
    zone_id=$(_dns_get_zone_id "$domain")
    if [[ -z "$zone_id" ]]; then
        printf_error "Зона для '${domain}' не найдена."
        return
    fi

    local resp
    resp=$(_dns_cf_api GET "/zones/${zone_id}/dns_records?type=A&per_page=100")

    # Собираем записи в массив
    local ids=() names=() ips=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local rid rname rip
        rid=$(echo "$line" | cut -d'|' -f1)
        rname=$(echo "$line" | cut -d'|' -f2)
        rip=$(echo "$line" | cut -d'|' -f3)
        ids+=("$rid"); names+=("$rname"); ips+=("$rip")
    done < <(echo "$resp" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('result', []):
    print(f'{r[\"id\"]}|{r[\"name\"]}|{r[\"content\"]}')
" 2>/dev/null)

    if [[ ${#ids[@]} -eq 0 ]]; then
        printf_warning "Нет A-записей для удаления."
        return
    fi

    echo ""
    for i in "${!ids[@]}"; do
        printf_menu_option "$((i+1))" "${names[$i]} -> ${ips[$i]}"
    done
    echo ""

    local del_choice
    del_choice=$(safe_read "Номер записи для удаления: " "") || return

    if [[ -z "$del_choice" || "$del_choice" -lt 1 || "$del_choice" -gt ${#ids[@]} ]] 2>/dev/null; then
        printf_error "Неверный выбор."
        return
    fi

    local target_id="${ids[$((del_choice-1))]}"
    local target_name="${names[$((del_choice-1))]}"
    local target_ip="${ips[$((del_choice-1))]}"

    if ! ask_yes_no "Удалить ${target_name} -> ${target_ip}?"; then
        info "Отмена."
        return
    fi

    local del_resp
    del_resp=$(_dns_cf_api DELETE "/zones/${zone_id}/dns_records/${target_id}")
    if echo "$del_resp" | grep -q '"success":true'; then
        printf_ok "Запись удалена: ${target_name} -> ${target_ip}"
    else
        printf_error "Не удалось удалить запись."
    fi
}

# --- 4. Массово добавить IP серверов из флота ---
_dns_add_fleet_ips() {
    print_separator
    printf_info "Массовое добавление IP серверов флота"
    print_separator

    if [[ ! -s "$FLEET_DATABASE_FILE" ]]; then
        printf_error "База флота пуста."
        return
    fi

    local domain
    domain=$(ask_non_empty "Базовый домен (например, example.com): ") || return

    local zone_id
    zone_id=$(_dns_get_zone_id "$domain")
    if [[ -z "$zone_id" ]]; then
        printf_error "Зона для '${domain}' не найдена в Cloudflare."
        return
    fi
    printf_ok "Зона найдена: ${domain}"

    local subdomain
    subdomain=$(safe_read "Поддомен (Enter = корень ${domain}): " "")

    local full_name
    if [[ -n "$subdomain" ]]; then
        full_name="${subdomain}.${domain}"
    else
        full_name="${domain}"
    fi

    local proxied="false"
    if ask_yes_no "Проксировать через Cloudflare?" "n"; then
        proxied="true"
    fi

    echo ""
    printf_info "Серверы флота:"
    local fleet_ips=() fleet_names=()
    local idx=1
    while IFS='|' read -r name user ip port key_path _rest; do
        fleet_ips+=("$ip")
        fleet_names+=("$name")
        printf "   [%d] %s — %s\n" "$idx" "$name" "$ip"
        ((idx++))
    done < "$FLEET_DATABASE_FILE"

    echo ""
    local selection
    selection=$(safe_read "Номера серверов через запятую (или 'all' для всех): " "all") || return

    # Собираем выбранные индексы
    local selected=()
    if [[ "$selection" == "all" || "$selection" == "a" ]]; then
        for i in "${!fleet_ips[@]}"; do selected+=("$i"); done
    else
        # Парсим "1,3,5" или "1, 3, 5" или "1-3,5"
        IFS=',' read -ra parts <<< "$selection"
        for part in "${parts[@]}"; do
            part=$(echo "$part" | tr -d ' ')
            if [[ "$part" == *-* ]]; then
                local from="${part%-*}" to="${part#*-}"
                for ((n=from; n<=to; n++)); do
                    [[ -n "${fleet_ips[$((n-1))]:-}" ]] && selected+=("$((n-1))")
                done
            else
                [[ -n "${fleet_ips[$((part-1))]:-}" ]] && selected+=("$((part-1))")
            fi
        done
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        printf_error "Ни один сервер не выбран."
        return
    fi

    echo ""
    printf_warning "Будет создано ${#selected[@]} A-записей: ${full_name}"
    for i in "${selected[@]}"; do
        printf "   • %s — %s\n" "${fleet_names[$i]}" "${fleet_ips[$i]}"
    done
    printf_info "Старые записи НЕ затираются — новые добавляются рядом."

    if ! ask_yes_no "Добавить?"; then
        info "Отмена."
        return
    fi

    for i in "${selected[@]}"; do
        local ip="${fleet_ips[$i]}"
        local name="${fleet_names[$i]}"
        printf_info "  ${name}: ${full_name} -> ${ip} ..."

        local resp
        resp=$(_dns_cf_api POST "/zones/${zone_id}/dns_records" \
            "{\"type\":\"A\",\"name\":\"${full_name}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":${proxied}}")

        if echo "$resp" | grep -q '"success":true'; then
            printf_ok "  Добавлено: ${ip}"
        else
            local err_msg
            err_msg=$(echo "$resp" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
            printf_error "  Ошибка для ${ip}: ${err_msg:-неизвестно}"
        fi
    done

    printf_ok "Готово!"
}
