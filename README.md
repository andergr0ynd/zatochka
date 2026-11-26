<p align="center">
  <img src="images/readme-banner.svg" width="100%" alt="AutoZatochka — заточка без лишних кликов. Одежда, оружие и карты Arizona RP.">
</p>

<p align="center">
  <a href="https://github.com/andergr0ynd/zatochka/releases/latest/download/AutoZatochka.zip"><img src="images/download-package.svg" width="285" alt="Скачать готовый комплект AutoZatochka с библиотеками и звуком"></a>
  &nbsp;
  <a href="https://github.com/andergr0ynd/zatochka/releases/latest/download/autozatochka.lua"><img src="images/download-script.svg" width="285" alt="Скачать только autozatochka.lua"></a>
  &nbsp;
  <a href="https://www.blast.hk/threads/257714/"><img src="images/download-blast.svg" width="285" alt="Скачать с Blast.hk — открыть тему автозаточки"></a>
</p>

<p align="center">
  <strong>Версия на GitHub: 1.39</strong> · Windows · Arizona RP · MoonLoader<br>
  Выбери предмет и целевой уровень — скрипт выполнит повторяющиеся действия заточки.
</p>

<p align="center">
  <a href="#install">Установка</a> &nbsp;·&nbsp;
  <a href="#start">Первый запуск</a> &nbsp;·&nbsp;
  <a href="#modes">Режимы</a> &nbsp;·&nbsp;
  <a href="#faq">Вопросы</a> &nbsp;·&nbsp;
  <a href="https://www.blast.hk/threads/257714/">Тема на Blast</a>
</p>

---

## Один скрипт — три направления

| Где точить | Что поддерживается |
| :--- | :--- |
| **Мастерская одежды** | Аксессуары, скины, бронежилеты и обычные нашивки |
| **Магазин оружия** | Скины на оружие и обвесы |
| **Эликсир мастер** | Улучшение карт из инвентаря |

Выбор целевого уровня, установка ресурсов на станок, счётчики попыток по уровням и звуковой сигнал успеха — в одном меню **`/mt`**.

<a id="install"></a>

## Установка за три шага

**1. Подготовь игру.** Нужны **MoonLoader**, **SAMPFUNCS**, **mimgui**, **SAMP.Lua** и стандартные библиотеки твоей сборки MoonLoader. [Подробнее о зависимостях ↓](#dependencies)

**2. Скачай [готовый комплект](https://github.com/andergr0ynd/zatochka/releases/latest/download/AutoZatochka.zip)** и распакуй его содержимое **в папку `moonloader`**, сохраняя вложенные папки:

```text
moonloader/
├── autozatochka.lua
├── lib/
│   ├── arizona-cef-dialogs.lua
│   └── arizona-events/
│       ├── init.lua
│       ├── core.lua
│       ├── bitstream.lua
│       └── subprocess.lua
└── autozatochka/
    └── applepay.mp3
```

**3. Зайди в игру и введи `/mt`.** Если игра уже запущена, сначала перезагрузи скрипты.

> [!IMPORTANT]
> Устанавливай **одну копию** автозаточки. Перед заменой файла убери старую копию из `moonloader`, даже если она называется иначе.

<details>
<summary><strong>У меня уже стоят библиотеки — можно скачать только Lua?</strong></summary>

Да. Скачай [autozatochka.lua](https://github.com/andergr0ynd/zatochka/releases/latest/download/autozatochka.lua), положи его в `moonloader` и перезагрузи скрипты.

Звук и логотип меню загружаются автоматически, если их нет в папке скрипта. Логотип сохраняется в `moonloader/images/autozatochka-logo.png`. Библиотеки при ручной установке возьми из [lib](lib); готовый комплект уже содержит их. Определение типов предметов встроено в основной Lua-файл и использует базу установленного клиента Arizona.

</details>

<a id="start"></a>

## Первый запуск

1. Открой нужную мастерскую **в игре** и подготовь предмет и ресурсы.
2. Введи **`/mt`** и выбери соответствующий раздел.
3. Для одежды или оружия выбери предмет в игровом окне — его тип определяется автоматически.
4. Выбери целевой уровень кнопкой **`+N`**. Скрипт начнёт работу, если доступны нужный интерфейс и ресурсы.
5. Следи за текущим уровнем, доступными ресурсами и счётчиком попыток в меню.

**Остановить заточку:** повторно нажми выбранный уровень или кнопку **«Назад»** в рабочем разделе.

> [!NOTE]
> `/mt` открывает и скрывает меню. Чтобы остановить процесс, используй выбор уровня или «Назад», а не только закрытие окна.

<a id="modes"></a>

## Какой раздел выбрать

| Раздел в `/mt` | Действие |
| :--- | :--- |
| **Мастерская одежды** | Аксессуары, скины, бронежилеты и нашивки: тип предмета определяется автоматически |
| **Магазин оружия** | Скины на оружие и обвесы: тип предмета определяется автоматически |
| **Эликсир мастер** | Подготовь карты в инвентаре справа; на попытку нужны две карты |

Для обычных нашивок на аксессуар поддерживаются урон, защита, регенерация, удача и максимальное HP. Ресурс — точильный амулет; доступны цели **+2 и +3**. Реальный уровень читается из данных инвентаря, поскольку игровой текст попытки может показывать неверные значения. Достигнув +3, скрипт прекращает заточку, в том числе после повторного входа при получении актуальных данных предмета.


<a id="faq"></a>

## Частые вопросы

<details>
<summary><strong>Меню не открывается по /mt</strong></summary>

Проверь, что файл находится в `moonloader`, установлены MoonLoader и mimgui, а старая копия скрипта удалена. Перезагрузи скрипты и посмотри `moonloader.log`: ошибка загрузки обычно указывает на отсутствующий модуль.

</details>

<details>
<summary><strong>Меню есть, но заточка не начинается</strong></summary>

Проверь, что открыт нужный игровой раздел, выбран подходящий режим и целевой уровень, а предмет и ресурсы доступны. Для карт нужны две подходящие карты в инвентаре справа.

Если сообщение указывает на отсутствующие `arizona-events`, дождись скачивания и перезапуска. При неудачной загрузке используй библиотеки из готового комплекта.

Для обращения за помощью укажи версию, мастерскую, предмет, выбранный уровень и текст сообщения или ошибки.

</details>

<details>
<summary><strong>Где должен лежать звук?</strong></summary>

Файл называется **`applepay.mp3`** и находится по пути:

```text
moonloader/autozatochka/applepay.mp3
```

Он включён в готовый комплект и доступен [отдельным файлом](https://github.com/andergr0ynd/zatochka/releases/latest/download/applepay.mp3). Скрипт также пытается скачать отсутствующий звук при запуске. Звук используется для сигнала успешной заточки.

</details>

<details>
<summary><strong>Как обновить скрипт?</strong></summary>

Останови заточку, скачай актуальный `autozatochka.lua`, замени файл в `moonloader` и перезагрузи скрипты. Не оставляй рядом старую версию под другим именем.

Автоматическая докачка библиотек и звука не означает обновление самого Lua-файла.

</details>

<a id="dependencies"></a>

<details>
<summary><strong>Библиотеки и файлы проекта</strong></summary>

**Устанавливаются заранее:** MoonLoader, SAMPFUNCS, [mimgui](https://github.com/THE-FYP/mimgui), [SAMP.Lua](https://github.com/THE-FYP/SAMP.Lua) и стандартные библиотеки сборки. Упоминание SAMP.Lua означает папку `samp`, в том числе модуль `samp.events`.

**Есть в готовом комплекте:** `arizona-cef-dialogs.lua`, четыре файла `arizona-events` и `applepay.mp3`. При ручной установке библиотеки из [lib](lib) помещаются в `moonloader/lib`.

**Содержимое репозитория:**

| Файл или папка | Назначение |
| :--- | :--- |
| [autozatochka.lua](autozatochka.lua) | Опубликованный скрипт |
| [lib](lib) | Библиотеки в структуре MoonLoader |
| [arizona-events](arizona-events) | Файлы прежнего загрузчика; сохранены для совместимости со старыми версиями |
| [applepay.mp3](applepay.mp3) | Звук успешной заточки |
| [version.json](version.json) | Информация о версии и адрес скрипта |

Автор `arizona-cef-dialogs` — **XRLM**; заголовок исходной библиотеки сохранён.

</details>

---

### Нужна помощь или нашёл ошибку?

[**Сообщить об ошибке →**](https://github.com/andergr0ynd/zatochka/issues/new?template=bug_report.yml) · [Тема на Blast.hk](https://www.blast.hk/threads/257714/) · [Скачать комплект](https://github.com/andergr0ynd/zatochka/releases/latest/download/AutoZatochka.zip)

<sub>AutoZatochka для Arizona RP · Автор — andergr0ynd.</sub>
