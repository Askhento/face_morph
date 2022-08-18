# VK facemorph template

Это шаблон маски с деформацией лица. В проекте есть файл face_models.blend, в котором создаются нужные формы лица.

Использование (Blender):

1. Выбрать версию facemodel, такая же как и в mask.json
2. Добавить или удалить ключи. Запомнить названия ключей, они пригодятся.
   ![Скрин1](https://user-images.githubusercontent.com/34323808/185414672-4a4894c9-684d-45a2-a83a-86760351f227.png)
3. Перейти в "Режим редактирования" (TAB), изменяем форму лица. Обязательно выйти в "Обьектный режим" (TAB) чтобы сохранить деформацию.

![Скрин2](https://user-images.githubusercontent.com/34323808/185414708-fbcc60d3-f78d-4cfb-b1d2-e616a0df6dc1.png) 4. Перейти во вкладку рендеринга. 5. В самом низу Urho Export 6. Нажать VK face 7. Указать путь до проекта маски 8. Нажать "Экспортировать"

![Скрин3](https://user-images.githubusercontent.com/34323808/185414713-17925f0a-7f0f-4cbf-8e4a-afe51ddb8191.png)

Далее переходим в маску и настраиваем mask.json:

```cpp
{
  "name": "facemorph",
  "model": "Models/face_v0.mdl",
  "debug": false,
  "keys": [
    { "name": "Key 1", "weight": 0.0 },
    { "name": "Key 2", "weight": 1.0 }
  ]
}
```

- model - это файл полученный из Blender
- debug - можно посмотреть отладочный вид и в консоли выводится дополнительная информация о модели
- keys - массив из обьектов, здесь важно указать в поле "name" то же ключи что и указаны в Blender

Возможные ошибки:

- facemodel_version должен соответствовать версии модели
- нельзя изменять топологию модели
- забыли нажать "VK face" в Blender перед экспортом
