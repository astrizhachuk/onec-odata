# Регистры: наборы записей и виртуальные таблицы

Источник: «Руководство разработчика», разделы «Правила формирования имени ресурса», «Выполнение функций и действий», «Выполнение типовых операций» (8.3.16: 17.2.1.4, 17.2.1.9, 17.2.1.13; с 8.3.21: 17.4.4, 17.4.9, 17.4.13).

## Сигнатуры - из $metadata

Виртуальная таблица - функция, привязанная к набору регистра. Набор параметров зависит от регистра и версии платформы, поэтому сигнатуру бери из `odata.sh meta <Регистр>` (строки `function`). Пример со стенда 8.3.16:

```
AccumulationRegister_ТоварыНаСкладах
  function  Balance(Condition:Edm.String, Dimensions:Edm.String, Period:Edm.DateTime)
  function  Turnovers(Condition:Edm.String, Dimensions:Edm.String, EndPeriod:Edm.DateTime, StartPeriod:Edm.DateTime)
  function  BalanceAndTurnovers(Condition:Edm.String, Dimensions:Edm.String, EndPeriod:Edm.DateTime, StartPeriod:Edm.DateTime)
InformationRegister_КурсыВалют
  function  SliceLast(Condition:Edm.String, Period:Edm.DateTime)
  function  SliceFirst(Condition:Edm.String, Period:Edm.DateTime)
```

Параметр `Dimensions` (перечень измерений) есть в `$metadata`, но в документации не описан.

Имена функций - английские имена виртуальных таблиц языка запросов:

| Виртуальная таблица | Функция |
| --- | --- |
| СрезПоследних, СрезПервых | `SliceLast`, `SliceFirst` |
| Остатки, Обороты, ОстаткиИОбороты | `Balance`, `Turnovers`, `BalanceAndTurnovers` |
| ОборотыДтКт, Субконто, ДвиженияССубконто (бухгалтерия) | `DrCrTurnovers`, `ExtDimensions`, `RecordsWithExtDimensions` |

Если функции нет в `meta`, значит она для этого регистра не опубликована: не подбирай имя наугад.

## Синтаксис вызова

Параметры - парами `Имя=Значение` через запятую в скобках. Отбор `Condition` - строка с выражением по правилам `$filter`. Кавычки литералов внутри `Condition` не удваиваются - так в примерах документации:

```bash
bash $S -p ut get "InformationRegister_КурсыВалют/SliceLast()" --select "Валюта_Key,Курс,Period" --top 5
bash $S -p ut get "InformationRegister_КурсыВалют/SliceFirst(Period=datetime'2008-01-01T00:00:00',Condition='Валюта_Key eq guid'<guid>'')"
bash $S -p ut get "AccumulationRegister_ТоварыЗапасы/BalanceAndTurnovers(StartPeriod=datetime'2014-01-01T00:00:00',EndPeriod=datetime'2014-02-01T00:00:00',Condition='Товар_Key eq guid'<guid>'')"
```

Документация приводит и форму с параметром запроса - `SliceLast?Condition=...`, ее передавай через `--param "Condition=..."`.

Отбор и `$select` к результату виртуальной таблицы применяются как к обычному набору. Бери `Condition` по конкретным измерениям, а не `$filter` по результату: условие внутри виртуальной таблицы сужает выборку на сервере до расчета остатков.

Регистр бухгалтерии, остатки по счету с условием по субконто:

```
AccountingRegister_Хозрасчетный/Balance(AccountCondition='Account_Key eq guid'<счет>'',Condition='ExtDimension1 eq cast(guid'<контрагент>', 'Catalog_Контрагенты')',ExtraDimensions='<вид субконто>')
```

## Набор записей по регистратору

Самый быстрый способ увидеть движения документа - набор записей по ключу регистратора:

```bash
bash $S -p ut get "AccumulationRegister_ТоварыНаСкладах(Recorder='<guid>', Recorder_Type='StandardODATA.Document_ПеремещениеТоваров')" \
  --select "RecordSet/Номенклатура_Key,RecordSet/Количество,RecordSet/RecordType"
```

Состав ключа смотри в `meta`: для регистра с одним типом регистратора хватает `Recorder_Key=guid'...'` (в документации - `InformationRegister_ПриходныеЦены(Recorder_Key=guid'value')`, `AccountingRegister_X(guid'value')`). Ответ «Экземпляр сущности не найден» (код 9) - у документа нет движений по этому регистру.

Отдельные записи с отбором по нескольким регистраторам - через набор `_RecordType` и `cast`:

```bash
bash $S -p ut count AccumulationRegister_ТоварыНаСкладах_RecordType \
  --filter "Recorder eq cast(guid'<guid>', 'Document_ПеремещениеТоваров')"
```

Запись независимого регистра сведений - по всем ключам: `InformationRegister_КурсыВалют(Period=datetime'...', Валюта_Key=guid'...')`.
