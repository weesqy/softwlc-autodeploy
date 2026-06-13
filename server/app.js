const express = require('express');
const bcrypt = require('bcrypt');
const session = require('express-session'); 
const mysql = require('mysql2');
const app = express();

app.use(express.urlencoded({ extended: true }));
app.use(express.json());

const dbWireless = mysql.createConnection({
  host: 'localhost',
  user: 'javauser',
  password: 'javapassword',
  database: 'wireless'
});

const dbRadius = mysql.createConnection({
  host: 'localhost',
  user: 'javauser',
  password: 'javapassword',
  database: 'radius'
});

dbWireless.connect(err => {
  if (err) {
    console.error('Ошибка подключения к базе данных Wireless:', err);
    return;
  }
  console.log('Подключение к базе данных Wireless установлено.');
});

dbRadius.connect(err => {
  if (err) {
    console.error('Ошибка подключения к базе данных Radius:', err);
    return;
  }
  console.log('Подключение к базе данных Radius установлено.');
});


let lastName = '';
let groupName = '';

app.get('/', (req, res) => {
  res.send(`
    <form action="/save-user-info" method="POST">
      <label>Введите фамилию:</label>
      <input type="text" name="lastname" required>
      <br>
      <label>Введите вашу группу:</label>
      <input type="text" name="groupname" required>
      <br>
      <button type="submit">Сохранить</button>
    </form>
    <p><small>Примечание: при вводе фамилии и группы используйте английскую раскладку.</small></p>
  `);
});

function replaceRussianChars(input) {
  const russianToEnglishMap = {
    'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'e',
    'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
    'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
    'ф': 'f', 'х': 'kh', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'shch',
    'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya'
  };

  return input.split('').map(char => russianToEnglishMap[char.toLowerCase()] || char).join('');
}

app.post('/save-user-info', (req, res) => {
  let { lastname, groupname } = req.body;

  // Интерпретируем русские буквы
  lastname = replaceRussianChars(lastname);
  groupname = replaceRussianChars(groupname);

  lastName = lastname;
  groupName = groupname;

  res.redirect('/select-lab');
});

app.get('/select-lab', (req, res) => {
  res.send(`
    <h1>${lastName}</h1>
    <p>Выберите лабораторную работу</p>
    <form action="/lab1" method="GET"><button type="submit">ЛР 1 PSK</button></form>
    <form action="/lab2" method="GET"><button type="submit">ЛР 2 Enterprise</button></form>
    <form action="/lab3" method="GET"><button type="submit">ЛР 3 Portals</button></form>
  `);
});

app.get('/lab1', (req, res) => {
  const networkName = lastName.slice(0, 6);
  res.send(`
    <h1>${lastName}</h1>
    <p>Задание 1: Создать сеть с названием: ${networkName}</p>
    <p>Задание 2: Создать привязку созданной сети</p>
    <form action="/verify-lab1" method="POST">
      <button type="submit">Проверить</button>
    </form>
  `);
});

app.post('/verify-lab1', (req, res) => {
  const networkName = lastName.slice(0, 6);

  dbWireless.query(`SELECT id FROM SSID WHERE name = ?`, [networkName], (err, ssidResults) => {
    if (err) {
      return res.send('Ошибка при выполнении запроса к базе данных Wireless.');
    }

    let networkResult = ssidResults.length > 0 ? `Да, сеть с названием ${networkName} создана.` : `Нет, сеть с названием ${networkName} не создана.`;
    const ssidId = ssidResults.length > 0 ? ssidResults[0].id : null;

    if (ssidId) {
      dbWireless.query(`SELECT * FROM SSID_LINK WHERE ssid_id = ?`, [ssidId], (err, linkResults) => {
        if (err) {
          return res.send('Ошибка при выполнении запроса к базе данных Wireless.');
        }

        let linkResult = linkResults.length > 0 ? 'Да, привязка создана.' : 'Нет, привязка не создана.';
        res.send(`
          <h1>${lastName} (${groupName})</h1>
          <p>Результат:</p>
          <p>Задача 1: ${networkResult}</p>
          <p>Задача 2: ${linkResult}</p>
          <form action="/lab1" method="GET"><button>Вернуться к заданию</button></form>
          <form action="/select-lab" method="GET"><button>Завершить ЛР1 PSK</button></form>
          <a href="/">На главную</a>
        `);
      });
    } else {
      res.send(`
        <h1>${lastName} (${groupName})</h1>
        <p>Результат:</p>
        <p>Задача 1: ${networkResult}</p>
        <p>Задача 2: Нет, привязка не создана.</p>
        <form action="/lab1" method="GET"><button>Вернуться к заданию</button></form>
        <form action="/select-lab" method="GET"><button>Завершить ЛР1 PSK</button></form>
        <a href="/">На главную</a>
      `);
    }
  });
});

 // лаборатроная работа 2
app.get('/lab2', (req, res) => {
  const networkName = `Ent_${lastName.slice(0, 6)}`;
  const userName = `User${lastName.slice(0, 6)}`;
  const firstPart = lastName.slice(0, 6);
  const letterToNumberMap = {
    a: "1", b: "2", c: "3", d: "4", e: "5", f: "6", g: "7", h: "8", i: "9", j: "0",
    k: "1", l: "2", m: "3", n: "4", o: "5", p: "6", q: "7", r: "8", s: "9", t: "0",
    u: "1", v: "2", w: "3", x: "4", y: "5", z: "6"
  };

  const lastTwoLetters = lastName.slice(-2).toLowerCase();
  const digit1 = letterToNumberMap[lastTwoLetters[0]] || "0";
  const digit2 = letterToNumberMap[lastTwoLetters[1]] || "0";

  const password = `${firstPart}${digit1}${digit2}`;

  res.send(`
    <h1>${lastName}</h1>
    <p>Задание 1: Создать SSID с названием: ${networkName}</p>
    <p>Задание 2: Создать Wi-Fi пользователя: ${userName}</p>
    <p>Задание 3: Создать пароль для Wi-Fi пользователя: ${password}</p>
    <p>Задание 4: Создать привязку созданному SSID</p>
    <p>Задание 5: Сделать SSID с типом: Enterprise</p>
    <p>Задание 6: Сделать у SSID режим безопасности: WPA Enterprise</p>
    <form action="/verify-lab2" method="POST">
      <input type="hidden" name="networkName" value="${networkName}">
      <input type="hidden" name="userName" value="${userName}">
      <input type="hidden" name="password" value="${password}">
      <button type="submit">Проверить</button>
    </form>
  `);
});

app.post('/verify-lab2', (req, res) => {
  const { networkName, userName, password } = req.body;

  dbWireless.query(`SELECT id, ssidtype, security FROM SSID WHERE name = ?`, [networkName], (err, ssidResults) => {
    if (err) {
      return res.send('Ошибка при выполнении запроса к базе данных Wireless.');
    }

    let networkResult = ssidResults.length > 0 ? `Да, SSID ${networkName} существует.` : `Нет, SSID ${networkName} не создана.`;
    const ssidId = ssidResults.length > 0 ? ssidResults[0].id : null;
    const ssidType = ssidResults.length > 0 ? ssidResults[0].ssidtype : null;
    const securityMode = ssidResults.length > 0 ? ssidResults[0].security : null;

    const task5Result = ssidType === 1 ? "Да, тип Enterprise выбран" : "Нет, тип Enterprise не выбран";
    const task6Result = securityMode === 5 ? "Да, режим безопасности WPA Enterprise выбран" : "Нет, режим безопасности WPA Enterprise не выбран";

    dbRadius.query(`SELECT * FROM radcheck WHERE username = ? AND value = ?`, [userName, password], (err, userResults) => {
      if (err) {
        return res.send('Ошибка при выполнении запроса к базе данных Radius.');
      }

      let userResult = userResults.length > 0 ? `Да, Wi-Fi пользователь ${userName} создан.` : `Нет, Wi-Fi пользователь ${userName} не создан.`;
      let passwordResult = userResults.length > 0 ? `Да, пароль ${password} был создан.` : `Нет, пароль ${password} не был создан.`;

      if (ssidId) {
        dbWireless.query(`SELECT * FROM SSID_LINK WHERE ssid_id = ?`, [ssidId], (err, linkResults) => {
          if (err) {
            return res.send('Ошибка при выполнении запроса к базе данных Wireless.');
          }

          let linkResult = linkResults.length > 0 ? 'Да, привязка создана.' : 'Нет, привязка не создана.';

          dbWireless.query(`SELECT param_value FROM SSID_PARAMS WHERE parent_id = ? AND param_name = 'radiusip'`, [ssidId], (err, ipResults) => {
            if (err) {
              return res.send('Ошибка при выполнении запроса для IP.');
            }
            const radiusIp = ipResults.length > 0 ? ipResults[0].param_value : 'не найден';

            dbWireless.query(`SELECT param_value FROM SSID_PARAMS WHERE parent_id = ? AND param_name = 'radiuskey'`, [ssidId], (err, keyResults) => {
              if (err) {
                return res.send('Ошибка при выполнении запроса для Radius Key.');
              }
              const radiusKey = keyResults.length > 0 ? keyResults[0].param_value : 'не найден';

              res.send(`
                <h1>${lastName}(${groupName})</h1>
                <p>Результаты проверки:</p>
                <p>Задача 1: ${networkResult}</p>
                <p>Задача 2: ${userResult}</p>
                <p>Задача 3: ${passwordResult}</p>
                <p>Задача 4: ${linkResult}</p>
                <p>Задача 5: ${task5Result}</p>
                <p>Задача 6: ${task6Result}</p>
                <p>Используемый Radius сервер IP: ${radiusIp}</p>
                <p>Radius Key: ${radiusKey}</p>
                <form action="/lab2" method="GET"><button>Вернуться к заданию</button></form>
                <form action="/select-lab" method="GET"><button>Завершить ЛР2 Enterprise</button></form>
                <a href="/">На главную</a>
              `);
            });
          });
        });
      } else {
        res.send(`
          <h1>${lastName}(${groupName})</h1>
          <p>Результаты проверки:</p>
          <p>Задача 1: ${networkResult}</p>
          <p>Задача 2: ${userResult}</p>
          <p>Задача 3: ${passwordResult}</p>
          <p>Задача 4: Нет, привязка не создана.</p>
          <p>Задача 5: ${task5Result}</p>
          <p>Задача 6: ${task6Result}</p>
          <p>Используемый Radius сервер IP: не найден</p>
          <p>Radius Key: не найден</p>
          <form action="/lab2" method="GET"><button>Вернуться к заданию</button></form>
          <form action="/select-lab" method="GET"><button>Завершить ЛР2 Enterprise</button></form>
          <a href="/">На главную</a>
        `);
      }
    });
  });
});

// лаборатроная работа 3
app.get('/lab3', (req, res) => {
  const networkName = `Portal_${lastName.slice(0, 6)}`;
  const userName = `PortalUser${lastName.slice(0, 6)}`;
  const firstPart = lastName.slice(0, 6);
  const letterToNumberMap = {
    a: "1", b: "2", c: "3", d: "4", e: "5", f: "6", g: "7", h: "8", i: "9", j: "0",
    k: "1", l: "2", m: "3", n: "4", o: "5", p: "6", q: "7", r: "8", s: "9", t: "0",
    u: "1", v: "2", w: "3", x: "4", y: "5", z: "6"
  };

  const lastTwoLetters = lastName.slice(-2).toLowerCase();
  const digit1 = letterToNumberMap[lastTwoLetters[0]] || "0";
  const digit2 = letterToNumberMap[lastTwoLetters[1]] || "0";

  const password = `${firstPart}${digit1}${digit2}`;

  res.send(`
    <h1>${lastName}</h1>
    <p>Задание 1: Создать SSID с названием: ${networkName}</p>
    <p>Задание 2: Создать Wi-Fi пользователя: ${userName}</p>
    <p>Задание 3: Создать пароль для Wi-Fi пользователя: ${password}</p>
    <p>Задание 4: Создать привязку созданному SSID</p>
    <p>Задание 5: Сделать SSID с типом: Hotspot</p>
    <p>Задание 6: Сделать у SSID режим безопасности: Open(без пароля)</p>
    <form action="/verify-lab3" method="POST">
      <input type="hidden" name="networkName" value="${networkName}">
      <input type="hidden" name="userName" value="${userName}">
      <input type="hidden" name="password" value="${password}">
      <button type="submit">Проверить</button>
    </form>
  `);
});

app.post('/verify-lab3', (req, res) => {
  const { networkName, userName, password } = req.body;

  dbWireless.query(`SELECT id, ssidtype, security FROM SSID WHERE name = ?`, [networkName], (err, ssidResults) => {
    if (err) {
      return res.send('Ошибка при выполнении запроса к базе данных Wireless.');
    }

    let networkResult = ssidResults.length > 0 ? `Да, SSID ${networkName} существует.` : `Нет, SSID ${networkName} не создана.`;
    const ssidId = ssidResults.length > 0 ? ssidResults[0].id : null;
    const ssidType = ssidResults.length > 0 ? ssidResults[0].ssidtype : null;
    const securityMode = ssidResults.length > 0 ? ssidResults[0].security : null;

    const task5Result = ssidType === 0 ? "Да, тип Hotspot выбран" : "Нет, тип Hotspot не выбран";
    const task6Result = securityMode === 1 ? "Да, режим безопасности Open(без пароля) выбран" : "Нет, режим безопасности Open(без пароля)не выбран";

    dbRadius.query(`SELECT * FROM radcheck WHERE username = ? AND value = ?`, [userName, password], (err, userResults) => {
      if (err) {
        return res.send('Ошибка при выполнении запроса к базе данных Radius.');
      }

      let userResult = userResults.length > 0 ? `Да, Wi-Fi пользователь ${userName} создан.` : `Нет, Wi-Fi пользователь ${userName} не создан.`;
      let passwordResult = userResults.length > 0 ? `Да, пароль ${password} был создан.` : `Нет, пароль ${password} не был создан.`;

      if (ssidId) {
        dbWireless.query(`SELECT * FROM SSID_LINK WHERE ssid_id = ?`, [ssidId], (err, linkResults) => {
          if (err) {
            return res.send('Ошибка при выполнении запроса к базе данных Wireless.');
          }

          let linkResult = linkResults.length > 0 ? 'Да, привязка создана.' : 'Нет, привязка не создана.';

            res.send(`
              <h1>${lastName}(${groupName})</h1>
              <p>Результаты проверки:</p>
              <p>Задача 1: ${networkResult}</p>
              <p>Задача 2: ${userResult}</p>
              <p>Задача 3: ${passwordResult}</p>
              <p>Задача 4: ${linkResult}</p>
              <p>Задача 5: ${task5Result}</p>
              <p>Задача 6: ${task6Result}</p>
              <form action="/lab3" method="GET"><button>Вернуться к заданию</button></form>
              <form action="/select-lab" method="GET"><button>Завершить ЛР3 Portals</button></form>
              <a href="/">На главную</a>
            `);
          });
      } else {
        res.send(`
          <h1>${lastName}(${groupName})</h1>
          <p>Результаты проверки:</p>
          <p>Задача 1: ${networkResult}</p>
          <p>Задача 2: ${userResult}</p>
          <p>Задача 3: ${passwordResult}</p>
          <p>Задача 4: Нет, привязка не создана.</p>
          <p>Задача 5: ${task5Result}</p>
          <p>Задача 6: ${task6Result}</p>
          <form action="/lab3" method="GET"><button>Вернуться к заданию</button></form>
          <form action="/select-lab" method="GET"><button>Завершить ЛР3 Portals</button></form>
          <a href="/">На главную</a>
        `);
      }
    });
  });
});




app.use(express.urlencoded({ extended: true }));

// Конфигурация сессий
app.use(session({
  secret: "e32c4dcd47f8963a1929b76b8dd7c82763fb5f69c632e3dbb1c3bff0948aa299", // Секретный ключ
  resave: false,
  saveUninitialized: false,
  cookie: {
    secure: false, // Установите true, если используете HTTPS
    httpOnly: true,
    maxAge: null // Сессия завершится при закрытии браузера
  }
}));

// Конфигурация логина и пароля
const ADMIN_LOGIN = 'admin';
const PASSWORD_HASH = '$2b$10$US20ApmD3QqjRrC92OsVR.bUtj0AQHtWdlH1bugYOL00nHJLprd4u'; // Предварительно захешированный пароль

// --- Маршрут для отображения страницы авторизации ---
app.get('/login', (req, res) => {
  res.send(`
    <h1>Авторизация</h1>
    <form action="/login" method="POST">
      <label>Логин:</label>
      <input type="text" name="login" required>
      <br>
      <label>Пароль:</label>
      <input type="password" name="password" required>
      <br>
      <button type="submit">Войти</button>
    </form>
  `);
});

// --- Маршрут для обработки авторизации ---
app.post('/login', (req, res) => {
  const { login, password } = req.body;

  if (login === ADMIN_LOGIN && bcrypt.compareSync(password, PASSWORD_HASH)) {
    req.session.isAuthenticated = true; // Устанавливаем флаг авторизации
    res.redirect('/teacher'); // Переход в кабинет преподавателя
  } else {
    res.send(`
      <h1>Авторизация</h1>
      <p>Неверный логин или пароль.</p>
      <a href="/login">Попробовать снова</a>
    `);
  }
});

// --- Middleware для проверки авторизации ---
function checkAuth(req, res, next) {
  if (req.session.isAuthenticated) {
    next(); // Пользователь авторизован, продолжаем
  } else {
    res.redirect('/login'); // Перенаправляем на авторизацию
  }
}

// --- Маршрут для кабинета преподавателя ---
app.get('/teacher', checkAuth, (req, res) => {
  res.send(`
    <h1>Кабинет преподавателя</h1>
    <p>Добро пожаловать, преподаватель!</p>
    <form action="/teacher/actions" method="POST">
      <button type="submit" name="action" value="view">Просмотр заданий студентов</button>
      <button type="submit" name="action" value="verify">Проверить выполнение заданий</button>
      <button type="submit" name="action" value="settings">Настройки</button>
    </form>
    <a href="/logout">Выход</a>
  `);
});

// --- Маршрут для действий в кабинете ---
app.post('/teacher/actions', checkAuth, (req, res) => {
  const { action } = req.body;

  if (action === 'view') {
    res.send(`
      <h1>Просмотр заданий студентов</h1>
      <p>Список выполненных заданий студентов будет добавлен позже.</p>
      <a href="/teacher">Назад в кабинет</a>
    `);
  } else if (action === 'verify') {
    res.send(`
      <h1>Проверка выполнения заданий</h1>
      <p>Функция проверки будет добавлена позже.</p>
      <a href="/teacher">Назад в кабинет</a>
    `);
  } else if (action === 'settings') {
    res.send(`
      <h1>Настройки</h1>
      <p>Настройки кабинета преподавателя будут добавлены позже.</p>
      <a href="/teacher">Назад в кабинет</a>
    `);
  } else {
    res.send(`
      <h1>Неизвестное действие</h1>
      <p>Действие не распознано.</p>
      <a href="/teacher">Назад в кабинет</a>
    `);
  }
});

// --- Выход из системы ---
app.get('/logout', (req, res) => {
  req.session.destroy(err => {
    if (err) {
      return res.send('Ошибка при выходе.');
    }
    res.redirect('/login');
  });
});

// --- Главная страница ---
app.get('/', (req, res) => {
  res.send(`
    <h1>Главная страница</h1>
    <p>Добро пожаловать на главную страницу.</p>
    <a href="/login">Авторизоваться</a>
  `);
});

app.listen(9090, () => {
  console.log('Сервер запущен на порту 9090');
});
