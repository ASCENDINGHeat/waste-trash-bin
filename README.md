# ESP-IDF Project

Initial ESP-IDF project scaffold.

## Project Structure

```text
.
├── CMakeLists.txt
├── sdkconfig.defaults
├── README.md
└── main
    ├── CMakeLists.txt
    ├── Kconfig.projbuild
    └── main.c
```

## Build & Flash

```bash
idf.py set-target esp32
idf.py build
idf.py -p PORT flash monitor
```
