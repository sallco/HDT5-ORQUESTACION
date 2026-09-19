# HDT5 — Orquestación Multiagente (Parachute S.A.)

Sistema Multiagente (MAS) para atención al cliente, evaluación meteorológica y calendarización de saltos en paracaídas para el evento nacional Guatemala 2026.

Implementa **tres arquitecturas de orquestación** sobre una capa compartida de dominio e integraciones:
1. **Centralizada**: Un orquestador principal que delega en especialistas mediante `as_tool()`.
2. **Jerárquica**: Un orquestador raíz que coordina supervisores de dominio (`Conocimiento` y `Operaciones`), los cuales a su vez coordinan agentes hoja.
3. **Descentralizada**: Red de agentes pares que se transfieren el control entre sí mediante `handoff()`, preservando contexto sin un coordinador central.

> 📄 **Informe técnico completo (PDF):** [`docs/Hoja de trabajo 5 - Orquestación.pdf`](docs/Hoja%20de%20trabajo%205%20-%20Orquestaci%C3%B3n.pdf) *(análisis comparativo, métricas y respuestas a preguntas de diseño)*. Ver [previsualización abajo](#5-documentación-e-informe-técnico).

---

## 1. Arquitecturas de Orquestación

### Arquitectura 1: Centralizada (`arch_centralizada.py`)

Un único agente orquestador atiende al usuario y coordina a los especialistas como herramientas (`as_tool()`). El control siempre retorna al centro antes de emitir una respuesta consolidada.

```mermaid
graph TD
    U["Usuario"] <--> O["Orquestador Central<br/>(Único punto de contacto)"]
    
    O -->|as_tool: consultar_faqs| A1["Especialista FAQs<br/>(Conocimiento institucional)"]
    O -->|as_tool: consultar_clima_seguridad| A2["Especialista Clima/Seguridad<br/>(Pronóstico y Veredicto)"]
    O -->|as_tool: gestionar_agenda| A3["Especialista Agenda<br/>(Cupos y Citas)"]

    A1 --> T1[("PostgreSQL + pgvector<br/>120 FAQs / HNSW")]
    A2 --> T2["API Open-Meteo<br/>(Ventana 08-16h)"]
    A2 --> T3["core/safety.py<br/>(Reglas deterministas)"]
    A3 --> T4[("PostgreSQL: citas<br/>(Restricción única fecha/hora)")]
```

### Arquitectura 2: Jerárquica (`arch_jerarquica.py`)

Estructura de dos niveles de decisión: el Orquestador Raíz delega en un **Supervisor de Conocimiento** (FAQs y políticas) y un **Supervisor de Operaciones**, quien impone la secuencia obligatoria: `clima -> evaluación de seguridad -> agenda`.

```mermaid
graph TD
    U["Usuario"] <--> R["Orquestador Raíz<br/>(Dirección y Síntesis)"]
    
    R -->|as_tool| S1["Supervisor de Conocimiento<br/>(FAQs y Políticas)"]
    R -->|as_tool| S2["Supervisor de Operaciones<br/>(Impositor de secuencia técnica)"]

    S1 -->|as_tool| H1["Agente FAQs Hoja"]
    S1 -->|as_tool| H2["Agente Políticas Hoja"]

    S2 -->|as_tool: 1. Clima| H3["Agente Clima Hoja"]
    S2 -->|as_tool: 2. Veredicto| H4["Agente Evaluación Hoja"]
    S2 -->|as_tool: 3. Reserva| H5["Agente Agenda Hoja"]

    H1 --> T1[("PostgreSQL + pgvector<br/>faqs")]
    H3 --> T2["API Open-Meteo<br/>(08-16h)"]
    H4 --> T3["core/safety.py<br/>(Veredicto Python)"]
    H5 --> T4[("PostgreSQL: citas<br/>(Transaccional)")]
```

### Arquitectura 3: Descentralizada (`arch_descentralizada.py`)

Red de pares autónomos sin coordinador permanente. La atención inicia en `agente_faqs` y el control se transfiere dinámicamente mediante `handoff()` según el dominio requerido.

```mermaid
graph LR
    U["Usuario"] <--> F["Agente FAQs<br/>(Receptor inicial)"]
    
    F <-->|handoff: clima / viabilidad| C["Agente Clima / Seguridad"]
    C <-->|handoff: reservar con evidencia| A["Agente Agenda / Citas"]
    A <-->|handoff: dudas institucionales| F
    A <-->|handoff: falta evidencia clima| C

    F --> T1[("PostgreSQL + pgvector<br/>faqs")]
    C --> T2["API Open-Meteo + safety.py"]
    A --> T3[("PostgreSQL: citas<br/>(Guardarraíl determinista)")]
```

---

## 2. Decisiones Técnicas y Guardarraíles Críticos

1. **Evaluación de Seguridad Determinista en Python Puro (`core/safety.py`)**:
   - El LLM **nunca** calcula ni relaja umbrales de seguridad.
   - Viento: `< 20 km/h` (IDEAL), `20–28 km/h` (MARGINAL: solo tándem experimentado), `> 28 km/h` (PROHIBIDO).
   - Ráfagas: `> 35 km/h` (PROHIBIDO).
   - Precipitación: `> 0.0 mm` (PROHIBIDO).
   - Nubes: `< 30%` (IDEAL), `30–75%` (MARGINAL), `> 75%` (PROHIBIDO).
   - Temperatura: Informativa, sin veto.
   - Veredicto global: El **peor** de los estados individuales.

2. **Ventana Operativa de Salto (08:00–16:00) vs Agregación Diaria 24h**:
   - En las coordenadas del Pacífico guatemalteco (`14.013722, -90.771611`), la temporada lluviosa de septiembre/octubre presenta chubascos nocturnos y nubosidad de tormenta que provocarían que `precipitation_sum > 0` y `cloud_cover_max > 75%` en prácticamente el 100% de los días a nivel de 24 horas.
   - Por ello, el sistema adopta como modo principal la **agregación sobre la franja diurna operativa (08:00 a 16:00)** consultando las variables horarias de Open-Meteo. También se soporta modo `--mock-clima ideal|marginal|prohibido` para pruebas reproducibles.

3. **Invariante de Evidencia Meteorológica por Turno**:
   - Para evitar fallos de red o latencia al confirmar citas, la evidencia meteorológica obtenida es válida durante todo el turno de conversación.
   - La función `agendar_cita` verifica que: `fecha_cita == fecha_evidencia`, `coords == coords_base` y `veredicto != PROHIBIDO`.

4. **Persistencia Transaccional con Restricción Única**:
   - Tabla `citas` en PostgreSQL con restricción `UNIQUE (fecha, hora)` que impide sobrecupos (1 cita por franja de 1 hora, 8 franjas diarias de 08:00 a 15:00).
   - Idempotencia garantizada por clave única.

---

## 3. Instalación y Configuración

### 3.1 Requisitos Previos y Entorno por Sistema Operativo

El proyecto requiere **Python 3.10 o superior** y **Docker / Docker Compose** para ejecutar el servicio PostgreSQL con `pgvector`. A continuación se detallan las instrucciones para cada plataforma:

#### 🐧 Linux

##### Arch Linux
```bash
# 1. Instalar paquetes base (Python, Docker y Git)
sudo pacman -S python python-pip docker docker-compose git

# 2. Habilitar e iniciar el demonio de Docker
sudo systemctl enable --now docker

# 3. (Opcional) Agregar tu usuario al grupo docker para evitar requerir sudo
sudo usermod -aG docker $USER
# Aplica el nuevo grupo en tu sesión actual:
newgrp docker

# 4. Crear y activar el entorno virtual
python -m venv .venv
source .venv/bin/activate

# 5. Instalar dependencias
pip install --upgrade pip
pip install -r requirements.txt
```

##### Ubuntu / Debian
```bash
# 1. Instalar paquetes necesarios
sudo apt update
sudo apt install -y python3 python3-venv python3-pip docker.io docker-compose-v2 git

# 2. Habilitar e iniciar Docker
sudo systemctl enable --now docker
sudo usermod -aG docker $USER

# 3. Crear y activar entorno virtual
python3 -m venv .venv
source .venv/bin/activate

# 4. Instalar dependencias
pip install --upgrade pip
pip install -r requirements.txt
```

##### Fedora
```bash
# 1. Instalar paquetes base
sudo dnf install -y python3 python3-pip docker docker-compose git
sudo systemctl enable --now docker
sudo usermod -aG docker $USER

# 2. Crear entorno virtual y activar
python3 -m venv .venv
source .venv/bin/activate

# 3. Instalar dependencias
pip install --upgrade pip
pip install -r requirements.txt
```

#### 🍏 macOS (Apple Silicon / Intel)

```bash
# 1. Instalar Homebrew (si no está instalado) y paquetes base
brew install python git

# 2. Instalar Docker Desktop para macOS
brew install --cask docker
# Abre Docker Desktop desde la carpeta de Aplicaciones y espera a que el servicio inicialice.

# 3. Crear y activar el entorno virtual
python3 -m venv .venv
source .venv/bin/activate

# 4. Instalar dependencias
pip install --upgrade pip
pip install -r requirements.txt
```

#### 🪟 Windows (PowerShell / WSL2)

Se recomienda el uso de **PowerShell 7** o la terminal integrada de Windows, junto con **Docker Desktop** (con backend WSL2 habilitado).

##### Opción A: Nativo en Windows con PowerShell
```powershell
# 1. Instalar Python, Git y Docker Desktop (mediante winget)
winget install Python.Python.3.12
winget install Docker.DockerDesktop
winget install Git.Git

# 2. Permitir la ejecución de scripts en la sesión actual de PowerShell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 3. Crear el entorno virtual
python -m venv .venv

# 4. Activar el entorno virtual en PowerShell
.venv\Scripts\Activate.ps1
# (En caso de usar el Símbolo del sistema / CMD clásico: .venv\Scripts\activate.bat)

# 5. Instalar dependencias
python -m pip install --upgrade pip
pip install -r requirements.txt
```

##### Opción B: Usando WSL2 (Ubuntu en Windows)
Si trabajas dentro de WSL2, abre tu terminal WSL (`wsl`) y sigue las instrucciones descritas en la sección de **Linux (Ubuntu / Debian)**.

---

### 3.2 Base de Datos PostgreSQL con pgvector

Una vez que el motor de Docker esté en ejecución, levanta el contenedor con la base de datos y la extensión vectorial:

```bash
docker compose up -d
docker compose ps
```
*(El comando es idéntico en Linux, macOS y Windows PowerShell/CMD).*

### 3.3 Configuración del archivo `.env`

Copia la plantilla de variables de entorno según tu sistema operativo:

- **Linux / macOS**:
  ```bash
  cp .env.example .env
  ```
- **Windows (PowerShell)**:
  ```powershell
  Copy-Item .env.example .env
  ```
- **Windows (CMD)**:
  ```cmd
  copy .env.example .env
  ```

Configura tus credenciales en el archivo `.env`:
```dotenv
NVIDIA_API_KEY=<tu-clave-de-nvidia>
OPENAI_BASE_URL=https://integrate.api.nvidia.com/v1
MODEL=openai/gpt-oss-20b
DATABASE_URL=postgresql://parachute:parachutepass@localhost:5432/parachutedb
FAQ_TABLE=faqs
CITAS_TABLE=citas
```

---

## 4. Guía de Ejecución

### 4.1 Carga del Corpus de FAQs
Genera embeddings normalizados de 384 dimensiones y carga las 120 FAQs en PostgreSQL:
```bash
python main.py load
```

### 4.2 Prueba de Humo con Fallback de Modelos
Valida la conectividad a NVIDIA NIM y comprueba tool calling, `as_tool()`, `handoff()` y desactivación de telemetría:
```bash
python main.py smoke-test
```

### 4.3 Ejecución del Chat en las Tres Arquitecturas

Puedes iniciar una sesión interactiva en cualquiera de las tres arquitecturas:

- **Arquitectura Centralizada (predeterminada)**:
  ```bash
  python main.py chat --arquitectura centralizada
  ```
- **Arquitectura Jerárquica**:
  ```bash
  python main.py chat --arquitectura jerarquica
  ```
- **Arquitectura Descentralizada**:
  ```bash
  python main.py chat --arquitectura descentralizada
  ```

*Nota: También puedes ejecutar directamente `python arch_centralizada.py`, `python arch_jerarquica.py` o `python arch_descentralizada.py`.*

#### 🧪 Simulación de Escenarios Meteorológicos con `--mock-clima`
Para probar determinísticamente los guardarraíles sin depender del clima real del día:
```bash
# Simular condiciones óptimas (viento bajo, despejado, sin lluvia)
python main.py chat --arquitectura centralizada --mock-clima ideal

# Simular condiciones de riesgo (lluvia o viento fuerte que veta la reserva)
python main.py chat --arquitectura centralizada --mock-clima prohibido
```

#### 💬 Ejemplos de Preguntas y Flujos para Probar

A continuación se presentan consultas sugeridas para validar la especialización de cada agente, las transferencias de control y los guardarraíles del sistema:

##### 1. Conocimiento y Políticas (FAQs RAG)
Prueba la recuperación semántica sobre la base de 120 preguntas frecuentes:
- *"¿Cuáles son los requisitos de peso y edad mínima para realizar un salto tándem?"*
- *"¿Qué tipo de ropa y calzado recomiendan llevar el día de la actividad?"*
- *"¿Qué certificaciones tienen los instructores y qué incluye el seguro de salto?"*

##### 2. Evaluación Meteorológica y Reglas de Seguridad
Prueba la consulta a Open-Meteo y el evaluador determinista en Python (`core/safety.py`):
- *"¿Es seguro saltar mañana? ¿Cómo estarán el viento y la nubosidad en la zona de salto?"*
- *"¿Se puede saltar el próximo sábado en la mañana en las coordenadas del evento?"*
- *"¿Qué sucede si hay ráfagas de viento mayores a 30 km/h el día de mi salto?"*

##### 3. Flujo Integrado: Consulta de Clima + Reserva de Cita
Prueba la coordinación completa: el sistema evalúa el clima y, solo si es viable, reserva en PostgreSQL:
- *"Hola, quiero agendar un salto para mañana a las 10:00 a nombre de Diego Calderón (correo: diego@example.com, tel: 5555-1234). ¿Las condiciones climáticas lo permiten?"*
- *"¿Hay cupos disponibles para pasado mañana entre las 09:00 y las 12:00? Si el clima es apto, resérvame a las 11:00 para María López (maria@example.com, tel: 4444-1234)."*

##### 4. Control de Límites y Preguntas Fuera de Dominio
Prueba que los agentes no alucinen ni desvíen su propósito:
- *"¿Me pueden vender un boleto de avión comercial hacia Flores, Petén?"* (debe declinar amablemente y enfocarse en saltos de paracaidismo de Parachute S.A.).
- *"¿Cuál es la receta para preparar un pastel de chocolate?"*

### 4.4 Pruebas Automatizadas
Ejecuta la suite completa de 40 pruebas unitarias y de integración (casos frontera de seguridad, fechas relativas, concurrencia de reservas y aislamiento de FAQs):
```bash
pytest tests/
```

### 4.5 Benchmark Comparativo de Arquitecturas
Ejecuta la matriz comparativa de latencia y respuestas:
```bash
python main.py benchmark
```
Los resultados observados se almacenan en `data/comparativa_arquitecturas.json`.

---

## 5. Documentación e Informe Técnico

El informe académico formal de la práctica, con las respuestas fundamentadas a las preguntas de diseño, el análisis crítico de desempeño y los diagramas de flujo, se encuentra disponible en formato PDF en la carpeta `docs/`:

- 📄 **Documento completo:** [docs/Hoja de trabajo 5 - Orquestación.pdf](docs/Hoja%20de%20trabajo%205%20-%20Orquestaci%C3%B3n.pdf)

### Previsualización del Informe

<p align="center">
  <a href="docs/Hoja%20de%20trabajo%205%20-%20Orquestaci%C3%B3n.pdf" title="Clic para abrir el PDF">
    <img src="docs/preview_informe.png" alt="Previsualización del Informe Técnico PDF" width="750"/>
  </a>
  <br/>
  <em>Haz clic en la imagen superior para abrir o descargar el documento PDF completo (4 páginas).</em>
</p>

