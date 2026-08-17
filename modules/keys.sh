#!/usr/bin/env bash
# freemind-setup/modules/keys.sh — сборщик бесплатных AI-ключей
# Не регистрирует за тебя (капчи/OAuth не обойти и не надо) — даёт ссылку на
# регистрацию, ждёт пока вставишь готовый ключ, складывает всё в один .env.
# Подключается через install.sh, использует функции из lib/common.sh

run_module() {
    step "Сборщик бесплатных AI-ключей — 8 сервисов"

    echo "Открывай каждую ссылку в браузере, регистрируйся (email/Google/GitHub — без карты),"
    echo "копируй ключ и вставляй сюда. Любой сервис можно пропустить — просто ответь N."

    mkdir -p ~/ai-keys
    local env_file=~/ai-keys/.env
    : > "$env_file"
    local configured=()

    collect_api_key "GROQ_API_KEY" "Groq — самый быстрый (LPU-чипы)" \
        "https://console.groq.com" "gsk_..., ~1000 запросов/день, Llama 3.3 70B + Whisper"

    collect_api_key "CEREBRAS_API_KEY" "Cerebras — самый щедрый лимит" \
        "https://cloud.cerebras.ai" "csk-..., 1 000 000 токенов/день"

    collect_api_key "GOOGLE_AI_STUDIO_KEY" "Google AI Studio — Gemini + Imagen" \
        "https://aistudio.google.com" "AIza..., 1.5М токенов/день, 1500 картинок/день"

    collect_api_key "OPENROUTER_API_KEY" "OpenRouter — 29 бесплатных моделей одним ключом" \
        "https://openrouter.ai" "sk-or-v1-..., DeepSeek R1/Llama/Qwen/Hermes 405B и др."

    collect_api_key "SAMBANOVA_API_KEY" "SambaNova — модели до 405B параметров" \
        "https://cloud.sambanova.ai" "\$5 кредитов + persistent free tier"

    collect_api_key "MISTRAL_API_KEY" "Mistral AI — Codestral для кода" \
        "https://console.mistral.ai" "Free Experiment tier, без карты"

    collect_api_key "TOGETHER_API_KEY" "Together AI — 200+ моделей + FLUX картинки" \
        "https://together.ai" "tgp_v1_..., \$100 кредитов при регистрации"

    collect_api_key "HF_TOKEN" "Hugging Face — тысячи open-source моделей" \
        "https://huggingface.co" "hf_..., бесплатный Inference API"

    if [ "${#configured[@]}" -eq 0 ]; then
        warn "Ни одного ключа не добавлено — файл ~/ai-keys/.env пустой. Запусти модуль заново, когда будут ключи."
    fi
    chmod 600 "$env_file"

    step "Готово"
    save_credentials "$HOME/ai-keys-credentials.txt" "$(cat << EOF
╔══════════════════════════════════════════════════╗
║  Бесплатные AI-ключи — собрано                     ║
╚══════════════════════════════════════════════════╝

Собрано сервисов: ${#configured[@]} из 8
$(printf '  ✓ %s\n' "${configured[@]}")

Файл: ~/ai-keys/.env (chmod 600)

Куда подставить дальше:
  OmniRoute:  cp ~/ai-keys/.env ~/omniroute/.env      (или дополни существующий)
  Hermes:     hermes config set <ИМЯ_КЛЮЧА> значение   (по одному, из ~/ai-keys/.env)
  n8n:        вставь значения в Credentials вручную

Не хватило ключей? Запусти модуль keys ещё раз — старые не потрёт, допишутся новые.
EOF
)"
}
