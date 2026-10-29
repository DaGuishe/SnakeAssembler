//===================================================================
// Plantilla de Interrupciones v4 - DE1-SoC (ARM Cortex-A9)
// Parcial 3: Snake con interrupciones y automata rival
// Arquitectura de Computadores - UIS 2026
//
// GLOSARIO (los terminos en ingles se definen aqui una sola vez;
// despues de definidos se usan libremente en el resto del archivo)
//
//   sondeo (polling)      Preguntar repetidamente a un periferico si
//                         ya tiene un dato nuevo. Se hace desde el
//                         bucle principal y consume tiempo de CPU.
//   interrupcion (IRQ)    El periferico avisa al procesador cuando
//                         tiene algo que informar. El bucle principal
//                         no tiene que preguntar nada.
//   rutina de servicio    Subrutina que atiende una interrupcion.
//     de interrupcion     Se abrevia ISR (Interrupt Service Routine).
//   bandera (flag)        Variable que vale 0 o 1 y recuerda que algo
//                         ocurrio.
//   codigo de pulsacion   Byte que el teclado PS/2 envia al OPRIMIR
//     (make code)         una tecla.
//   codigo de liberacion  Byte que el teclado PS/2 envia al SOLTAR
//     (break code)        una tecla. Va precedido de 0xF0.
//   captura de flanco     Registro que recuerda cual pulsador genero
//     (edge capture)      la interrupcion. Se limpia escribiendo unos.
//   mascara de            Registro que decide cuales pulsadores tienen
//     interrupcion        permitido generar interrupciones.
//   despachador           Rutina que pregunta al GIC quien interrumpio
//                         y llama a la ISR que corresponda.
//
// IDENTIFICADORES DE INTERRUPCION (confirmados en el DE1-SoC):
//   72 -> Temporizador de intervalos 0 (Interval Timer 0)
//   73 -> Pulsadores KEY0..KEY3
//   79 -> Teclado PS/2
//
// CONVENCION DE ZONAS:
//   // ZONA NO MODIFICAR //
//        Bloques que solo se copian al archivo final, sin cambios.
//   // ZONA DE TRABAJO DEL ESTUDIANTE //
//        Bloques vacios o incompletos que usted debe escribir.
//   // ZONA DE TRABAJO DEL ESTUDIANTE (COMPLETAR LO INDICADO) //
//        El bloque ya trae codigo: usted solo completa o corrige lo
//        que se enumera en el encabezado del bloque.
//
// AVISO: este archivo contiene errores intencionales que usted debe
//        localizar y corregir. Algunos estan en la inicializacion de
//        los modos IRQ y SVC; otros, posiblemente, en el despachador
//        de interrupciones.
//===================================================================

/*======================================================================
   // ZONA NO MODIFICAR //
   TABLA DE VECTORES - orden y contenido fijos por la arquitectura ARM
  ======================================================================*/
.section .vectors, "ax"
    B   _start              // 0x00 Reinicio (Reset)
    B   SERVICE_UND         // 0x04 Instruccion indefinida
    B   SERVICE_SVC         // 0x08 Llamada a supervisor (SWI)
    B   SERVICE_ABT_INST    // 0x0C Aborto de instruccion
    B   SERVICE_ABT_DATA    // 0x10 Aborto de datos
    .word 0                 // 0x14 Reservado
    B   SERVICE_IRQ         // 0x18 Interrupcion IRQ
    B   SERVICE_FIQ         // 0x1C Interrupcion rapida FIQ

/*======================================================================
   INICIALIZACION - _start
   Configura las pilas de los modos IRQ y SVC, registra las
   interrupciones en el GIC, configura los perifericos y entra al
   modo SVC con las interrupciones habilitadas.

   ATENCION: las dos pilas (IRQ y SVC) NO deben apuntar al mismo tope
   de memoria. Si lo hacen, la primera interrupcion que llegue pisa la
   pila del programa principal. Una de las dos en este archivo esta mal
   direccionada a proposito. Identifiquela y corrija el valor antes de
   fusionar los archivos.
  ======================================================================*/
.text
.global _start
_start:
    //-----------------------------------------------------------------
    // Pila del modo IRQ
    //-----------------------------------------------------------------
    MOV  R1, #0b11010010            // CPSR: I=1, F=1, modo IRQ (0x12)
    MSR  CPSR_c, R1
    LDR  SP, =0xFFFFFFFC            // Tope de la memoria interna del A9

    //-----------------------------------------------------------------
    // Pila del modo SVC
    //-----------------------------------------------------------------
    MOV  R0, #0b11010011            // CPSR: I=1, F=1, modo SVC (0x13)
    MSR  CPSR_c, R0
    LDR  SP, =0xFFFFFFFC            // Tope de pila

    //-----------------------------------------------------------------
    // Configurar el GIC y los perifericos
    //-----------------------------------------------------------------
    BL   SET_IRQs
    BL   CONFIG_INTERVAL_TIMER
    BL   CONFIG_KEYS
    BL   CONFIG_PS2

    //-----------------------------------------------------------------
    // Pasar a modo SVC con las interrupciones habilitadas (I=0)
    //-----------------------------------------------------------------
    MOV  R1, #0b01010011            // CPSR: I=0, F=1, modo SVC
    MSR  CPSR_c, R1

/*======================================================================
   PROGRAMA PRINCIPAL - MAIN

   Lo que hay aqui abajo es solo un marcador de posicion: una etiqueta
   que salta sobre si misma para que el archivo ensamble.

   EN EL ARCHIVO FUSIONADO usted debe borrar las dos lineas de MAIN y
   poner en su lugar el MainLoop completo de snakelogic_v4.s, que
   incluye:
     - Inicializacion de R7 a R12, primera fruta y ResetBot.
     - Las 7 fases del juego.
     - La rutina GameOver y el bucle GameOver_Loop (Parte 3.3).
  ======================================================================*/
MAIN:
    B    MAIN

/*======================================================================
   // ZONA NO MODIFICAR (solo agregar interrupciones nuevas) //
   SET_IRQs - registra cada identificador de interrupcion en el GIC
   Para agregar una interrupcion nueva:
     1. MOV R0, #<identificador>
     2. BL  CONFIG_GIC
  ======================================================================*/
SET_IRQs:
    PUSH {LR}
    MOV  R0, #72                    // 72 = Temporizador de intervalos 0
    BL   CONFIG_GIC
    MOV  R0, #73                    // 73 = Pulsadores KEY0..KEY3
    BL   CONFIG_GIC
    MOV  R0, #79                    // 79 = Teclado PS/2
    BL   CONFIG_GIC
    POP  {PC}

/*======================================================================
   // ZONA DE TRABAJO DEL ESTUDIANTE //
   CONFIG_INTERVAL_TIMER
   Programe el temporizador de intervalos 0 para generar una
   interrupcion aproximadamente cada segundo, en modo continuo.

   Mapa de registros (direccion base 0xFF202000):
     [0x00] Estado        bit 0 (TO): se limpia escribiendo 0
     [0x04] Control       bit 0 (ITO):   habilitar la interrupcion
                          bit 1 (CONT):  modo continuo
                          bit 2 (START): poner en marcha el temporizador
     [0x08] Carga baja    16 bits bajos del periodo
     [0x0C] Carga alta    16 bits altos del periodo

   Periodo para 1 Hz con reloj de 100 MHz:
     carga = 100 000 000 - 1 = 0x05F5E0FF
     parte baja = 0xE0FF
     parte alta = 0x05F5
  ======================================================================*/
CONFIG_INTERVAL_TIMER:
    PUSH {LR}
    // ESCRIBA SU CODIGO AQUI
    //   1. Cargar los valores de carga baja y carga alta.
    //   2. Escribir en Control los bits START, CONT e ITO.
    //   3. Comprobar con los LED o con un display que la frecuencia
    //      sea de aproximadamente 1 Hz.
    POP  {PC}

/*======================================================================
   // ZONA DE TRABAJO DEL ESTUDIANTE //
   CONFIG_KEYS
   Habilite la generacion de interrupciones por los pulsadores
   KEY0 a KEY3.

   Mapa de registros (direccion base 0xFF200050):
     [0x08] Mascara de interrupcion   bits 3:0 = 1 habilita la
                                      interrupcion de cada pulsador
     [0x0C] Captura de flanco         bits 3:0 indican cual pulsador
                                      disparo la interrupcion
                                      (se limpia escribiendo 0xF)
  ======================================================================*/
CONFIG_KEYS:
    PUSH {LR}
    // ESCRIBA SU CODIGO AQUI
    //   1. Limpiar la captura de flanco (escribir 0xF en [0x0C]).
    //   2. Habilitar los 4 pulsadores en la mascara ([0x08] = 0xF).
    POP  {PC}

/*======================================================================
   // ZONA DE TRABAJO DEL ESTUDIANTE //
   CONFIG_PS2
   Habilite la interrupcion por recepcion del teclado PS/2, es decir,
   que el teclado avise cada vez que llega un byte nuevo.

   Registro de control del PS/2 (direccion base 0xFF200100):
     [0x04] Control   bit 0 (RI): habilita la interrupcion por
                      recepcion (Receive Interrupt)

   Forma de la implementacion:
     LDR  R0, =0xFF200100
     MOV  R1, #1                    // RI = 1
     STR  R1, [R0, #4]
  ======================================================================*/
CONFIG_PS2:
    PUSH {LR}
    // ESCRIBA SU CODIGO AQUI
    POP  {PC}

/*======================================================================
   // ZONA NO MODIFICAR //
   CONFIG_GIC y CONFIG_INTERRUPT - controlador de interrupciones (GIC)
   Habilita el bit correspondiente en el ICDISER, configura el ICDIPTR
   y abre la interfaz de CPU (ICCICR + ICCPMR + ICDDCR).
  ======================================================================*/
.global CONFIG_GIC
CONFIG_GIC:
    PUSH {LR}
    MOV  R1, #1
    BL   CONFIG_INTERRUPT           // Habilitar el bit en el ICDISER

    LDR  R0, =0xFFFEC100            // Base de la interfaz de CPU
    LDR  R1, =0xFFFF                // Aceptar todos los niveles de prioridad
    STR  R1, [R0, #0x04]            // ICCPMR

    MOV  R1, #1
    STR  R1, [R0]                   // ICCICR: habilitar la interfaz de CPU

    LDR  R0, =0xFFFED000            // Base del distribuidor
    STR  R1, [R0]                   // ICDDCR: habilitar el distribuidor
    POP  {PC}

CONFIG_INTERRUPT:
    PUSH {R4-R5, LR}
    // Habilitar el bit N en el ICDISER (registro de habilitacion)
    LSR  R4, R0, #3
    BIC  R4, R4, #3                 // desplazamiento = (N / 32) * 4
    LDR  R2, =0xFFFED100
    ADD  R4, R2, R4                 // direccion del registro
    AND  R2, R0, #0x1F              // N modulo 32
    MOV  R5, #1
    LSL  R2, R5, R2                 // mascara de bit
    LDR  R3, [R4]
    ORR  R3, R3, R2
    STR  R3, [R4]

    // ICDIPTR: a cual procesador se entrega la interrupcion
    BIC  R4, R0, #3
    LDR  R2, =0xFFFED800
    ADD  R4, R2, R4
    AND  R2, R0, #0x3
    ADD  R4, R2, R4
    STRB R1, [R4]
    POP  {R4-R5, PC}

/*======================================================================
   // ZONA NO MODIFICAR //
   SERVICE_IRQ - despachador de interrupciones
   Lee el ICCIAR, averigua cual interrupcion esta pendiente y llama a
   la rutina de servicio que corresponda. Para agregar mas
   interrupciones en el futuro, repetir el patron:
   CMP / BNE / BL <rutina de servicio> / B EXIT_IRQ.
  ======================================================================*/
.global SERVICE_IRQ
SERVICE_IRQ:
    PUSH {R0-R7, LR}

    LDR  R4, =0xFFFEC100            // Base de la interfaz de CPU
    LDR  R5, [R4, #0x0C]            // ICCIAR: identificador pendiente

    // Temporizador de intervalos 0 (identificador 72)
    CMP  R5, #72
    BNE  IRQ_Check_Keys
    BL   TIMER_ISR
    B    EXIT_IRQ

    // Pulsadores KEY0..KEY3 (identificador 73)
IRQ_Check_Keys:
    CMP  R5, #73
    BNE  IRQ_Check_PS2
    BL   KEY_ISR
    B    EXIT_IRQ

    // Teclado PS/2 (identificador 79)
IRQ_Check_PS2:
    CMP  R5, #79
    BNE  IRQ_Unexpected
    BL   PS2_ISR
    B    EXIT_IRQ

    // Identificador desconocido: bucle infinito (configuracion invalida)
IRQ_Unexpected:
    B    IRQ_Unexpected

EXIT_IRQ:
    STR  R5, [R4, #0x10]            // ICCEOIR: fin de la interrupcion
    POP  {R0-R7, LR}
    SUBS PC, LR, #4                 // Retorno de interrupcion

/*======================================================================
   // ZONA DE TRABAJO DEL ESTUDIANTE //
   TIMER_ISR - rutina de servicio del temporizador
   Se ejecuta aproximadamente cada segundo. Tareas minimas:
     1. Limpiar la bandera TO del registro de estado del temporizador
        (escribir 0).
     2. Leer la variable 'puntaje' y mostrarla en los LED rojos y en
        los displays de 7 segmentos (binario -> BCD -> patron de
        segmentos).
     3. (Opcional) incrementar 'Contador' para depuracion.
  ======================================================================*/
.global TIMER_ISR
TIMER_ISR:
    PUSH {R4-R7, LR}
    LDR  R0, =0xFF202000            // Base del temporizador de intervalos 0
    MOV  R1, #0
    STR  R1, [R0]                   // Limpiar la bandera TO

    // Mostrar el puntaje en los LED rojos
    LDR  R0, =puntaje
    LDR  R1, [R0]
    LDR  R0, =0xFF200000            // Base de los LED rojos
    STR  R1, [R0]

    // COMPLETAR: mostrar el puntaje en HEX0..HEX3 (7 segmentos)
    //   Convertir primero de binario a BCD y despues a patron de
    //   segmentos. En KEY_ISR hay patrones de ejemplo para 0, 1, 2 y 3.

    // Contador interno (depuracion)
    LDR  R0, =Contador
    LDR  R1, [R0]
    ADD  R1, R1, #1
    STR  R1, [R0]

    POP  {R4-R7, LR}
    BX   LR

/*======================================================================
   // ZONA DE TRABAJO DEL ESTUDIANTE //
   KEY_ISR - rutina de servicio de los pulsadores
   Reaccione al pulsador que se haya oprimido. Tareas sugeridas:
     - KEY0: reiniciar la partida (estado_juego = 0, puntaje = 0).
     - KEY1: pausa (alternar una bandera).
     - KEY2: mostrar en HEX0 la longitud actual de la cola.
     - KEY3: conmutar la estrategia del automata rival (Parte 4).
   Recuerde limpiar la captura de flanco al final.
  ======================================================================*/
.global KEY_ISR
KEY_ISR:
    PUSH {LR}
    LDR  R0, =0xFF200050            // Base de los pulsadores
    LDR  R1, [R0, #0xC]             // Captura de flanco
    MOV  R2, #0xF
    STR  R2, [R0, #0xC]             // Limpiar todas las banderas

    LDR  R0, =0xFF200020            // Base de los 7 segmentos (HEX0)

CHECK_KEY0:
    TST  R1, #0x1
    BEQ  CHECK_KEY1
    MOV  R2, #0b00111111            // patron del "0"
    STR  R2, [R0]
    B    END_KEY_ISR

CHECK_KEY1:
    TST  R1, #0x2
    BEQ  CHECK_KEY2
    MOV  R2, #0b00000110            // patron del "1"
    STR  R2, [R0]
    B    END_KEY_ISR

CHECK_KEY2:
    TST  R1, #0x4
    BEQ  CHECK_KEY3
    MOV  R2, #0b01011011            // patron del "2"
    STR  R2, [R0]
    B    END_KEY_ISR

CHECK_KEY3:
    TST  R1, #0x8
    BEQ  END_KEY_ISR
    MOV  R2, #0b01001111            // patron del "3"
    STR  R2, [R0]

END_KEY_ISR:
    POP  {LR}
    BX   LR

/*======================================================================
   // ZONA DE TRABAJO DEL ESTUDIANTE (COMPLETAR LO INDICADO) //
   PS2_ISR - rutina de servicio del teclado PS/2

   Lo que ya viene escrito: la lectura del registro de datos, el manejo
   del prefijo 0xE0 de las teclas extendidas y el reparto entre las
   cuatro teclas de flecha.

   Lo que usted DEBE hacer:
     1. Comprobar que dir_pendiente_x y dir_pendiente_y reciben los
        valores correctos para CADA una de las cuatro flechas.
     2. Recordar que el filtro que impide el giro de 180 grados NO va
        aqui, sino en el MainLoop (Parte 2.3 del enunciado).
     3. (Bonificacion) Manejar el codigo de liberacion 0xF0 para que al
        SOLTAR una tecla no se produzca un movimiento no deseado.

   Reglas:
     - NO escriba directamente en R11 ni en R12. Use las variables
       dir_pendiente_x y dir_pendiente_y; el MainLoop se encarga de
       aplicarlas.
     - Leer el registro de datos limpia la interrupcion por si solo.
  ======================================================================*/
.global PS2_ISR
PS2_ISR:
    PUSH {R0-R4, LR}

    LDR  R0, =0xFF200100            // Base del teclado PS/2
    LDR  R1, [R0]                   // Registro de datos
    TST  R1, #0x8000                // Bit RVALID: hay dato valido?
    BEQ  PS2_ISR_End

    AND  R0, R1, #0xFF              // byte recibido

    // Manejo de la bandera E0 (prefijo de tecla extendida)
    LDR  R1, =bandera_e0_ps2
    LDR  R2, [R1]
    CMP  R2, #1
    BEQ  PS2_Handle_Extended

    // Byte normal: es el prefijo 0xE0?
    CMP  R0, #0xE0
    MOVNE R2, #0
    MOVEQ R2, #1
    STR  R2, [R1]
    B    PS2_ISR_End

    // Tecla extendida (el byte anterior fue 0xE0)
PS2_Handle_Extended:
    MOV  R2, #0
    STR  R2, [R1]                   // Limpiar bandera_e0_ps2

    // Flecha arriba (0x75): direccion pendiente = (0, -1)
    CMP  R0, #0x75
    BNE  PS2_Check_Down
    LDR  R3, =dir_pendiente_x
    MOV  R4, #0
    STR  R4, [R3]
    LDR  R3, =dir_pendiente_y
    MOV  R4, #-1
    STR  R4, [R3]
    B    PS2_ISR_End

    // Flecha abajo (0x72): direccion pendiente = (0, +1)
PS2_Check_Down:
    CMP  R0, #0x72
    BNE  PS2_Check_Left
    LDR  R3, =dir_pendiente_x
    MOV  R4, #0
    STR  R4, [R3]
    LDR  R3, =dir_pendiente_y
    MOV  R4, #1
    STR  R4, [R3]
    B    PS2_ISR_End

    // Flecha izquierda (0x6B): direccion pendiente = (-1, 0)
PS2_Check_Left:
    CMP  R0, #0x6B
    BNE  PS2_Check_Right
    LDR  R3, =dir_pendiente_x
    MOV  R4, #-1
    STR  R4, [R3]
    LDR  R3, =dir_pendiente_y
    MOV  R4, #0
    STR  R4, [R3]
    B    PS2_ISR_End

    // Flecha derecha (0x74): direccion pendiente = (+1, 0)
PS2_Check_Right:
    CMP  R0, #0x74
    BNE  PS2_ISR_End
    LDR  R3, =dir_pendiente_x
    MOV  R4, #1
    STR  R4, [R3]
    LDR  R3, =dir_pendiente_y
    MOV  R4, #0
    STR  R4, [R3]

PS2_ISR_End:
    POP  {R0-R4, LR}
    BX   LR

/*======================================================================
   // ZONA NO MODIFICAR //
   MANEJADORES DE EXCEPCIONES - bucles de captura
  ======================================================================*/
.global SERVICE_UND
SERVICE_UND:        B SERVICE_UND

.global SERVICE_SVC
SERVICE_SVC:        B SERVICE_SVC

.global SERVICE_ABT_DATA
SERVICE_ABT_DATA:   B SERVICE_ABT_DATA

.global SERVICE_ABT_INST
SERVICE_ABT_INST:   B SERVICE_ABT_INST

.global SERVICE_FIQ
SERVICE_FIQ:        B SERVICE_FIQ

/*======================================================================
   DATOS GLOBALES - seccion compartida con snakelogic_v4.s
   Al fusionar los dos archivos debe quedar UNA SOLA seccion .data con
   TODAS las variables de ambos. NO duplicar etiquetas.
  ======================================================================*/
.data
.align 2

// Variables de la plantilla de interrupciones
Contador:        .word 0        // Pulsos contados del temporizador

// Variables del estado de la partida
estado_juego:    .word 0        // 0 = jugando | 1 = fin de partida
puntaje:         .word 0        // Puntaje del jugador

// Variables de sincronizacion entre PS2_ISR y el MainLoop
bandera_e0_ps2:  .word 0        // Bandera de tecla extendida (0xE0)
dir_pendiente_x: .word 0        // Direccion horizontal pendiente (-1, 0, +1)
dir_pendiente_y: .word 0        // Direccion vertical pendiente   (-1, 0, +1)

.end
