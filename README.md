# AutoZatochka

Автозаточка для **Arizona RP** (MoonLoader + mimgui + arizona-events).

Команда в игре: `/mt`

## Возможности

- Автозаточка одежды, оружия и обвесов
- Режим **Эликсир мастер** (карты)
- Работа через CEF-верстак (`workShop` / `startEnchant`)
- Звук успеха (`applepay.mp3`)
- Автодокачка `lib/arizona-events`, если библиотеки нет

## Установка

1. Нужны **MoonLoader**, **mimgui**, **SAMPFUNCS/samp.events**
2. Скрипт: положи `autozatochka.lua` в `moonloader\`
3. Библиотеки: папка `arizona-events` ? `moonloader\lib\arizona-events\`  
   (скрипт может скачать сам при первом запуске)
4. Звук (опционально): `applepay.mp3` ? `moonloader\autozatochka\`

## Файлы репозитория

| Файл / папка | Назначение |
|---|---|
| `autozatochka.lua` | Основной скрипт |
| `arizona-events/` | Патченная библиотека Arizona CEF/packets |
| `applepay.mp3` | Звук успешной заточки |
| `version.json` | Версия для автообновления |

## Версия

Текущая: **1.26**

Репозиторий раньше назывался `zvyk`, теперь:  
https://github.com/andergr0ynd/zatochka
