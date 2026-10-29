//===================================================================
// Parcial 3 - Snake con interrupciones y automata rival
// DE1-SoC (ARM Cortex-A9) - Arquitectura de Computadores UIS 2026
// Autores: Sandoval - Gonzalez
//
// Archivo fusionado a partir de interrupt_template_v4.s y
// snakelogic_v4.s. Orden de los bloques:
//   1. Tabla de vectores
//   2. Inicializacion _start (pilas, GIC, perifericos)
//   3. Pantalla de inicio, NewGame y MainLoop (7 fases)
//      + GameOver / GameOver_Loop
//   4. Subrutinas del juego (dibujo, texto, fruta, colisiones,
//      automata rival)
//   5. Rutinas de interrupcion (configuracion, despachador, ISR)
//   6. Seccion .data unificada
//
// REGISTROS GLOBALES (uso fijo durante todo el MainLoop):
//   R7  = ya no se usa como bandera E0 (ahora la maneja PS2_ISR en
//         la variable bandera_e0_ps2)
//   R8  = contador de cuadros (tambien alimenta la semilla aleatoria)
//   R9  = cabeza_x          posicion horizontal de la cabeza
//   R10 = cabeza_y          posicion vertical de la cabeza
//   R11 = dir_x             direccion horizontal (-1, 0, +1)
//   R12 = dir_y             direccion vertical   (-1, 0, +1)
//   La cabeza avanza dir * BOX_SIZE pixeles por cuadro, de modo que
//   la serpiente, la fruta y el automata viven en una cuadricula de
//   32 x 24 casillas de 10 x 10 pixeles.
//
// CONVENCION DE SUBRUTINAS: R0-R3 de uso libre; R4-R12 se preservan.
//
// CONTROLES:
//   Flechas PS/2 ........ mover la serpiente
//   Espacio / Enter ..... empezar / reiniciar (tambien KEY0)
//   KEY1 ................ pausa
//   KEY3 ................ cambiar la personalidad del automata
//                         (HEX5 muestra G = glotona, C = cazadora)
//===================================================================

// Constantes de pantalla
.equ WIDTH,              320
.equ HEIGHT,             240
.equ BOX_SIZE,           10
.equ FOOD_SIZE,          10
.equ BOX_MAX_X,          310        // WIDTH  - BOX_SIZE
.equ BOX_MAX_Y,          230        // HEIGHT - BOX_SIZE
.equ GRID_COLS,          32         // columnas de la cuadricula (x = 0..310)
.equ GRID_ROWS,          24         // filas de la cuadricula    (y = 0..230)
.equ TEXT_COLS,          80         // buffer de caracteres: 80 x 60
.equ TEXT_ROWS,          60

// Ritmo del juego: vueltas de Delay por cuadro.
// Ajustar segun la plataforma (CPUlator es mas lento que la tarjeta).
.equ FRAME_DELAY,        300000

// Perifericos
.equ PIXBUF,             0xC8000000     // Memoria de video VGA
.equ CHARBUF,            0xC9000000     // Buffer de caracteres VGA
.equ LEDR_BASE,          0xFF200000     // LED rojos
.equ HEX3_0_BASE,        0xFF200020     // Displays HEX3..HEX0
.equ HEX5_4_BASE,        0xFF200030     // Displays HEX5..HEX4
.equ KEY_BASE,           0xFF200050     // Pulsadores KEY0..KEY3
.equ PS2_BASE,           0xFF200100     // Controlador del teclado PS/2
.equ TIMER_BASE,         0xFF202000     // Temporizador de intervalos 0

// Codigos de pulsacion PS/2
.equ KEY_SPACE,          0x29
.equ KEY_ENTER,          0x5A

// Automata rival
.equ BOT_MAX_LEN,        20         // cola maxima de la glotona
.equ HUNT_AHEAD,         1          // la cazadora apunta a N casillas delante de la cabeza
.equ GLOTONA_ESQUIVA,    0          // 1 = la glotona tambien esquiva a la serpiente

// Bono 1: puntaje dibujado pixel a pixel
.equ PIX_SCALE,          6          // cada pixel de la fuente 3x5 mide 6x6

// Colores de 16 bits en formato RGB565
.equ COLOR_BLACK,        0x0000
.equ COLOR_RED,          0xF800
.equ COLOR_GREEN,        0x07E0
.equ COLOR_BLUE,         0x001F
.equ COLOR_WHITE,        0xFFFF
.equ COLOR_YELLOW,       0xFFE0          // Cabeza del automata rival
.equ COLOR_ORANGE,       0xFC00          // Cola del automata rival
.equ COLOR_GREY,         0x8410          // Cola de la serpiente del jugador

/*======================================================================
   BLOQUE 1 - TABLA DE VECTORES (copiada sin modificar)
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
   BLOQUE 2 - INICIALIZACION _start
  ======================================================================*/
.text
.global _start
_start:
    //-----------------------------------------------------------------
    // Pila del modo IRQ: tope de la memoria interna (on-chip) del A9
    //-----------------------------------------------------------------
    MOV  R1, #0b11010010            // CPSR: I=1, F=1, modo IRQ (0x12)
    MSR  CPSR_c, R1
    LDR  SP, =0xFFFFFFFC

    //-----------------------------------------------------------------
    // Pila del modo SVC: tope de la DDR
    // CORREGIDO: la plantilla usaba 0xFFFFFFFC, el mismo tope que la
    // pila IRQ, y la primera interrupcion pisaba la pila del programa.
    //-----------------------------------------------------------------
    MOV  R0, #0b11010011            // CPSR: I=1, F=1, modo SVC (0x13)
    MSR  CPSR_c, R0
    LDR  SP, =0x3FFFFFFC

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
   BLOQUE 3 - PROGRAMA PRINCIPAL
  ======================================================================*/
    mov  r8,  #0                    // contador de cuadros = 0

    // Parte 5.1 - Pantalla de inicio: espera Espacio / Enter
    bl   StartScreen

//-------------------------------------------------------------------
// NewGame - estado inicial de una partida. Se llega aqui al arrancar
// y desde GameOver_Loop al reiniciar.
//-------------------------------------------------------------------
NewGame:
    mov  r7,  #0                    // (sin uso: la bandera E0 vive en memoria)
    mov  r9,  #50                   // cabeza_x inicial
    mov  r10, #50                   // cabeza_y inicial
    mov  r11, #1                    // dir_x inicial (hacia la derecha)
    mov  r12, #0                    // dir_y inicial

    bl   ResetGameState             // largo_cola, historial, puntaje, banderas
    bl   ClearScreen
    bl   ClearText
    bl   GenerateFood               // Primera fruta
    bl   ResetBot                   // Posicion inicial del automata rival
    bl   ResetBotCola               // ... y sin cola
    bl   ShowStrategy               // HEX5 = G (glotona)

//===================================================================
// BUCLE PRINCIPAL
//===================================================================
MainLoop:
    // Comprobar el estado de la partida (Parte 1.3)
    ldr  r0, =estado_juego
    ldr  r0, [r0]
    cmp  r0, #1
    beq  GameOver_Loop              // si la partida termino, esperar reinicio

    // Pausa (KEY1): no avanzar mientras la bandera este activa
    ldr  r0, =pausa
    ldr  r0, [r0]
    cmp  r0, #1
    beq  MainLoop

    //----------------------------------------------------------------
    // FASE 1 - BORRAR LOS OBJETOS DEL CUADRO ANTERIOR
    //----------------------------------------------------------------

    // 1a. Borrar la cabeza anterior
    mov  r0, r9
    mov  r1, r10
    mov  r2, #COLOR_BLACK
    bl   DrawSquare

    // 1b. Borrar la cola anterior
    // CORREGIDO: antes se saltaban los segmentos con x = 0 o y = 0,
    // que quedaban pintados en la pantalla.
    ldr  r0, =largo_cola
    ldr  r4, [r0]                   // r4 = n (longitud de la cola)
    ldr  r0, =indice_historial
    ldr  r6, [r0]                   // r6 = indice de la cabeza anterior
    mov  r5, #1
CleanTail_Loop:
    cmp  r5, r4
    bgt  CleanTail_End
    sub  r0, r6, r5
    and  r0, r0, #0xFF              // indice dentro del arreglo circular
    ldr  r3, =historial_pos
    add  r3, r3, r0, lsl #3
    ldr  r0, [r3, #0]               // x de la cola anterior
    ldr  r1, [r3, #4]               // y de la cola anterior
    mov  r2, #COLOR_BLACK
    bl   DrawSquare
    add  r5, r5, #1
    b    CleanTail_Loop
CleanTail_End:

    // 1c. Borrar la fruta anterior
    ldr  r0, =fruta_x
    ldr  r0, [r0]
    ldr  r1, =fruta_y
    ldr  r1, [r1]
    mov  r2, #COLOR_BLACK
    bl   DrawSquare

    // 1d. Borrar el automata rival anterior (cabeza y cola)
    ldr  r0, =bot_x
    ldr  r0, [r0]
    ldr  r1, =bot_y
    ldr  r1, [r1]
    mov  r2, #COLOR_BLACK
    bl   DrawSquare
    mov  r2, #COLOR_BLACK
    bl   DrawBotTail

    //----------------------------------------------------------------
    // FASE 2 - SINCRONIZAR LA DIRECCION QUE DEJO PS2_ISR (Parte 2.3)
    // Ya no hay sondeo del PS/2 en el MainLoop: solo se leen las dos
    // variables que escribe la rutina de servicio.
    //----------------------------------------------------------------
    ldr  r0, =dir_pendiente_x
    ldr  r3, [r0]                   // r3 = direccion horizontal candidata
    ldr  r0, =dir_pendiente_y
    ldr  r4, [r0]                   // r4 = direccion vertical candidata

    // Sin direccion pendiente (0, 0): conservar la actual
    orrs r0, r3, r4
    beq  Sync_End

    // Impedir el giro de 180 grados: la candidata es la opuesta si
    // candidata + actual = (0, 0)
    add  r0, r3, r11
    add  r1, r4, r12
    orrs r0, r0, r1
    beq  Sync_End                   // es la opuesta: se descarta

    mov  r11, r3                    // aplicar la direccion nueva
    mov  r12, r4
Sync_End:

    //----------------------------------------------------------------
    // FASE 3 - ACTUALIZAR LA POSICION DE LA CABEZA
    // CORREGIDO: la cabeza avanzaba 1 pixel por cuadro; ahora avanza
    // una casilla completa (BOX_SIZE), igual que el automata.
    //----------------------------------------------------------------
    mov  r0, #BOX_SIZE
    mla  r9,  r11, r0, r9           // cabeza_x += dir_x * BOX_SIZE
    mla  r10, r12, r0, r10          // cabeza_y += dir_y * BOX_SIZE

    //----------------------------------------------------------------
    // FASE 4 - COMPROBAR LIMITES (Parte 3.1): tocar un borde termina
    // la partida
    //----------------------------------------------------------------
    // Borde horizontal
    ldr  r0, =BOX_MAX_X
    cmp  r9, r0
    bgt  GameOver                   // borde derecho
    cmp  r9, #0
    blt  GameOver                   // borde izquierdo
    // Borde vertical
    ldr  r0, =BOX_MAX_Y
    cmp  r10, r0
    bgt  GameOver                   // borde inferior
    cmp  r10, #0
    blt  GameOver                   // borde superior

    //----------------------------------------------------------------
    // FASE 5 - ACTUALIZAR EL HISTORIAL DE POSICIONES DE LA COLA
    //----------------------------------------------------------------
    add  r6, r6, #1
    and  r6, r6, #0xFF              // indice circular (0 a 255)

    ldr  r4, =historial_pos
    add  r4, r4, r6, lsl #3
    str  r9,  [r4, #0]
    str  r10, [r4, #4]

    ldr  r0, =indice_historial
    str  r6, [r0]                   // actualizar el indice global

    // Auto-colision: cabeza contra cola (Parte 3.2)
    bl   CheckSelfCollision
    cmp  r0, #1
    beq  GameOver

    // La cabeza entro en la casilla del automata (cabeza o cola)?
    // Se comprueba antes de que el automata se mueva para que no
    // puedan "cruzarse" sin chocar.
    bl   CheckHeadVsBot
    cmp  r0, #1
    beq  GameOver
    bl   CheckHeadVsBotTail
    cmp  r0, #1
    beq  GameOver

    //----------------------------------------------------------------
    // FASE 5b - COLISION ENTRE LA CABEZA Y LA FRUTA
    //----------------------------------------------------------------
    bl   CheckCollision_FoodHead
    cmp  r0, #1
    bne  Skip_Eat

    ldr  r0, =largo_cola
    ldr  r5, [r0]
    cmp  r5, #250                   // el historial tiene 256 entradas
    addlt r5, r5, #1
    str  r5, [r0]

    bl   GenerateFood

    // Sumar puntaje (Parte 3.4)
    ldr  r0, =puntaje
    ldr  r1, [r0]
    add  r1, r1, #1
    str  r1, [r0]

    // Bono 2: con mas de 10 puntos el automata da dos pasos por cuadro
    cmp  r1, #10
    movgt r2, #2
    ldrgt r3, =velocidad_bot
    strgt r2, [r3]
Skip_Eat:

    //----------------------------------------------------------------
    // FASE 5c - AUTOMATA RIVAL: MOVER Y COMPROBAR COLISIONES
    //----------------------------------------------------------------

    // 5c-1. Mover el automata (velocidad_bot pasos por cuadro)
    ldr  r0, =velocidad_bot
    ldr  r4, [r0]
BotStep_Loop:
    bl   MoveBot
    bl   BotEatFood                 // la glotona come si esta sobre la fruta
    subs r4, r4, #1
    bgt  BotStep_Loop

    // 5c-2. El automata choco con la cabeza o la cola? -> reiniciarlo
    bl   CheckBotVsSnakeBody
    cmp  r0, #1
    bne  Skip_BotReset
    bl   ResetBot
    bl   ResetBotCola
Skip_BotReset:

    // 5c-3. La cabeza choco con el automata? -> fin de la partida
    bl   CheckHeadVsBot
    cmp  r0, #1
    beq  GameOver
    bl   CheckHeadVsBotTail
    cmp  r0, #1
    beq  GameOver

    //----------------------------------------------------------------
    // FASE 6 - DIBUJAR LOS OBJETOS EN SU NUEVA POSICION
    //----------------------------------------------------------------

    // 6a. Dibujar la fruta (el color alterna segun la paridad del cuadro)
    ldr  r0, =fruta_x
    ldr  r0, [r0]
    ldr  r1, =fruta_y
    ldr  r1, [r1]
    ldr  r4, =tabla_colores
    tst  r8, #1
    ldreq r2, [r4, #8]              // cuadro par -> azul
    ldrne r2, [r4, #0]              // cuadro impar -> rojo
    bl   DrawSquare

    // 6b. Dibujar la cabeza (color ciclico, indice = bits 0 a 2 del cuadro)
    mov  r0, r9
    mov  r1, r10
    and  r3, r8, #0x7
    ldr  r4, =tabla_colores
    ldr  r2, [r4, r3, lsl #2]
    bl   DrawSquare

    // 6c. Dibujar la cola
    ldr  r0, =largo_cola
    ldr  r5, [r0]
    mov  r4, #1
DrawTail_Loop:
    cmp  r4, r5
    bgt  DrawTail_End

    sub  r0, r6, r4
    and  r0, r0, #0xFF
    ldr  r3, =historial_pos
    add  r3, r3, r0, lsl #3
    ldr  r0, [r3, #0]
    ldr  r1, [r3, #4]
    ldr  r2, =COLOR_GREY
    bl   DrawSquare

    add  r4, r4, #1
    b    DrawTail_Loop
DrawTail_End:

    // 6d. Dibujar el automata rival: cola naranja y cabeza amarilla
    mov  r2, #COLOR_ORANGE
    bl   DrawBotTail
    ldr  r0, =bot_x
    ldr  r0, [r0]
    ldr  r1, =bot_y
    ldr  r1, [r1]
    ldr  r2, =COLOR_YELLOW
    bl   DrawSquare

    //----------------------------------------------------------------
    // FASE 7 - PAUSA Y CONTADOR DE CUADROS
    //----------------------------------------------------------------
    add  r8, r8, #1
    ldr  r0, =FRAME_DELAY
    bl   Delay

    b    MainLoop

//===================================================================
// GameOver - fin de partida (Parte 3.3)
// Marca estado_juego = 1, limpia la pantalla y muestra el mensaje y
// el puntaje. Despues cae en GameOver_Loop.
//===================================================================
GameOver:
    mov  r0, #1
    ldr  r1, =estado_juego
    str  r0, [r1]                   // estado_juego = 1

    mov  r0, #0
    ldr  r1, =tecla_inicio
    str  r0, [r1]                   // descartar teclas oprimidas durante el juego

    bl   ClearScreen                // limpiar la pantalla a negro
    bl   ClearText

    ldr  r0, =txt_game_over
    mov  r2, #16
    bl   PrintCentered
    ldr  r0, =txt_puntaje
    mov  r2, #22
    bl   PrintCentered

    ldr  r0, =puntaje               // Bono 1: puntaje pixel a pixel
    ldr  r0, [r0]
    mov  r1, #100                   // y en pixeles
    bl   DrawScorePixels

    ldr  r0, =txt_reiniciar
    mov  r2, #40
    bl   PrintCentered

//===================================================================
// GameOver_Loop - espera Espacio / Enter (o KEY0). PS2_ISR y KEY_ISR
// ponen tecla_inicio = 1; al detectarla se arranca una partida nueva
// desde cero en NewGame (R9-R12, largo_cola = 4, puntaje = 0,
// historial, estado_juego = 0, automata en (200, 120) y glotona).
//===================================================================
GameOver_Loop:
    ldr  r0, =tecla_inicio
    ldr  r1, [r0]
    cmp  r1, #1
    bne  GameOver_Loop
    mov  r1, #0
    str  r1, [r0]
    b    NewGame

.ltorg

//===================================================================
// BLOQUE 4 - SUBRUTINAS DEL JUEGO
//===================================================================

//-------------------------------------------------------------------
// ResetGameState - deja las variables de la partida como al comienzo.
// Entradas: R9, R10 = cabeza inicial (la cola se arma hacia la izquierda)
//-------------------------------------------------------------------
ResetGameState:
    push {r4-r5, lr}
    mov  r0, #0
    ldr  r1, =estado_juego
    str  r0, [r1]
    ldr  r1, =puntaje
    str  r0, [r1]
    ldr  r1, =pausa
    str  r0, [r1]
    ldr  r1, =estrategia_bot        // al iniciar, siempre glotona
    str  r0, [r1]
    ldr  r1, =tecla_inicio
    str  r0, [r1]
    ldr  r1, =indice_historial
    str  r0, [r1]
    ldr  r1, =dir_pendiente_y
    str  r0, [r1]
    mov  r0, #1
    ldr  r1, =dir_pendiente_x       // coincide con la direccion inicial
    str  r0, [r1]
    ldr  r1, =velocidad_bot
    str  r0, [r1]
    mov  r0, #4
    ldr  r1, =largo_cola            // longitud inicial
    str  r0, [r1]

    // Historial: la cabeza en el indice 0 y los 4 segmentos de la
    // cola a la izquierda de ella (indices 255, 254, 253, 252)
    ldr  r4, =historial_pos
    str  r9,  [r4, #0]
    str  r10, [r4, #4]
    mov  r5, #1
RGS_Loop:
    cmp  r5, #4
    bgt  RGS_End
    rsb  r0, r5, #0
    and  r0, r0, #0xFF              // (0 - i) dentro del arreglo circular
    add  r1, r4, r0, lsl #3
    mov  r2, #BOX_SIZE
    mul  r3, r5, r2
    sub  r2, r9, r3                 // x = cabeza_x - i * BOX_SIZE
    str  r2,  [r1, #0]
    str  r10, [r1, #4]
    add  r5, r5, #1
    b    RGS_Loop
RGS_End:
    pop  {r4-r5, lr}
    bx   lr

//-------------------------------------------------------------------
// StartScreen - pantalla de inicio (Parte 5.1). Muestra el nombre del
// juego, los autores y la instruccion, y espera Espacio / Enter.
//-------------------------------------------------------------------
StartScreen:
    push {r4, lr}
    bl   ClearScreen
    bl   ClearText

    ldr  r0, =txt_titulo
    mov  r2, #18
    bl   PrintCentered
    ldr  r0, =txt_curso
    mov  r2, #22
    bl   PrintCentered
    ldr  r0, =txt_autores
    mov  r2, #26
    bl   PrintCentered
    ldr  r0, =txt_empezar
    mov  r2, #34
    bl   PrintCentered
    ldr  r0, =txt_controles1
    mov  r2, #42
    bl   PrintCentered
    ldr  r0, =txt_controles2
    mov  r2, #44
    bl   PrintCentered

    mov  r0, #0
    ldr  r1, =tecla_inicio
    str  r0, [r1]
    ldr  r4, =semilla
SS_Wait:
    ldr  r0, [r4]                   // la semilla depende de cuanto se espere
    add  r0, r0, #1
    str  r0, [r4]
    ldr  r0, [r1]
    cmp  r0, #1
    bne  SS_Wait
    mov  r0, #0
    str  r0, [r1]

    bl   ClearText
    pop  {r4, lr}
    bx   lr

.ltorg

//===================================================================
// SUBRUTINAS - DIBUJO
//===================================================================

// DrawSquare(r0=x, r1=y, r2=color)
// Dibuja un cuadrado de BOX_SIZE por BOX_SIZE pixeles.
DrawSquare:
    push {r4-r7, lr}
    mov  r4, r0                     // x inicial
    mov  r5, r1                     // y inicial
    mov  r6, r2                     // color

    mov  r7, #0                     // contador vertical
DrawSq_Y:
    cmp  r7, #BOX_SIZE
    bge  DrawSq_End
    mov  r3, #0                     // contador horizontal
DrawSq_X:
    cmp  r3, #BOX_SIZE
    bge  DrawSq_NextY
    add  r0, r4, r3
    add  r1, r5, r7
    mov  r2, r6
    bl   WritePixelSafe
    add  r3, r3, #1
    b    DrawSq_X
DrawSq_NextY:
    add  r7, r7, #1
    b    DrawSq_Y
DrawSq_End:
    pop  {r4-r7, lr}
    bx   lr


// WritePixelSafe(r0=x, r1=y, r2=color)
// Escribe un pixel solo si la coordenada cae dentro de la pantalla.
WritePixelSafe:
    push {r3-r5}
    ldr  r3, =(WIDTH-1)             // 319
    cmp  r0, r3
    bgt  WPS_End
    cmp  r0, #0
    blt  WPS_End
    ldr  r3, =(HEIGHT-1)            // 239
    cmp  r1, r3
    bgt  WPS_End
    cmp  r1, #0
    blt  WPS_End
    lsl  r3, r1, #10                // y * 1024 (paso de fila en bytes)
    add  r3, r3, r0, lsl #1         // + x * 2 (dos bytes por pixel)
    ldr  r4, =PIXBUF
    add  r3, r4, r3
    strh r2, [r3]
WPS_End:
    pop  {r3-r5}
    bx   lr

// FillBlock(r0=x, r1=y, r2=color, r3=lado)
// Rellena un cuadrado de r3 x r3 pixeles.
FillBlock:
    push {r4-r8, lr}
    mov  r4, r0
    mov  r5, r1
    mov  r6, r2
    mov  r8, r3
    mov  r7, #0                     // contador vertical
FB_Y:
    cmp  r7, r8
    bge  FB_End
    mov  r3, #0                     // contador horizontal
FB_X:
    cmp  r3, r8
    bge  FB_NextY
    add  r0, r4, r3
    add  r1, r5, r7
    mov  r2, r6
    bl   WritePixelSafe
    add  r3, r3, #1
    b    FB_X
FB_NextY:
    add  r7, r7, #1
    b    FB_Y
FB_End:
    pop  {r4-r8, lr}
    bx   lr

// ClearScreen - pinta toda la memoria de video de negro
ClearScreen:
    push {r4, lr}
    ldr  r0, =PIXBUF
    mov  r1, #0                     // dos pixeles negros por palabra
    mov  r2, #0                     // fila
CS_Row:
    cmp  r2, #HEIGHT
    bge  CS_End
    add  r3, r0, r2, lsl #10        // comienzo de la fila
    mov  r4, #0                     // desplazamiento en bytes
CS_Col:
    cmp  r4, #(WIDTH*2)
    bge  CS_NextRow
    str  r1, [r3, r4]
    add  r4, r4, #4
    b    CS_Col
CS_NextRow:
    add  r2, r2, #1
    b    CS_Row
CS_End:
    pop  {r4, lr}
    bx   lr

// ClearText - llena el buffer de caracteres con espacios
ClearText:
    push {r4, lr}
    ldr  r0, =CHARBUF
    mov  r1, #0x20                  // espacio
    mov  r2, #0                     // fila
CT_Row:
    cmp  r2, #TEXT_ROWS
    bge  CT_End
    add  r3, r0, r2, lsl #7         // cada fila ocupa 128 bytes
    mov  r4, #0                     // columna
CT_Col:
    cmp  r4, #TEXT_COLS
    bge  CT_NextRow
    strb r1, [r3, r4]
    add  r4, r4, #1
    b    CT_Col
CT_NextRow:
    add  r2, r2, #1
    b    CT_Row
CT_End:
    pop  {r4, lr}
    bx   lr

// PrintString(r0=cadena terminada en 0, r1=columna, r2=fila)
PrintString:
    push {r4, lr}
    ldr  r3, =CHARBUF
    add  r3, r3, r2, lsl #7
    add  r3, r3, r1
PS_Loop:
    ldrb r4, [r0], #1
    cmp  r4, #0
    beq  PS_End
    strb r4, [r3], #1
    b    PS_Loop
PS_End:
    pop  {r4, lr}
    bx   lr

// PrintCentered(r0=cadena, r2=fila) - centra la cadena en 80 columnas
PrintCentered:
    push {r4, lr}
    mov  r1, #0                     // longitud
    mov  r4, r0
PCen_Len:
    ldrb r3, [r4], #1
    cmp  r3, #0
    addne r1, r1, #1
    bne  PCen_Len
    rsb  r1, r1, #TEXT_COLS
    asr  r1, r1, #1                 // columna = (80 - longitud) / 2
    bl   PrintString
    pop  {r4, lr}
    bx   lr

// DrawDigitPixels(r0=digito 0..9, r1=x, r2=y) - Bono 1
// Dibuja el digito con una fuente de 3x5 pixeles ampliada PIX_SCALE.
DrawDigitPixels:
    push {r4-r9, lr}
    ldr  r3, =fuente_digitos
    ldr  r4, [r3, r0, lsl #2]       // patron de 15 bits (bit 14 = arriba izq.)
    mov  r5, r1                     // x
    mov  r6, r2                     // y
    mov  r7, #14                    // bit actual
    mov  r8, #0                     // fila
DDP_Row:
    cmp  r8, #5
    bge  DDP_End
    mov  r9, #0                     // columna
DDP_Col:
    cmp  r9, #3
    bge  DDP_NextRow
    mov  r0, #1
    tst  r4, r0, lsl r7
    beq  DDP_Skip
    mov  r3, #PIX_SCALE
    mla  r0, r9, r3, r5             // x + columna * escala
    mla  r1, r8, r3, r6             // y + fila * escala
    ldr  r2, =COLOR_WHITE
    bl   FillBlock
DDP_Skip:
    sub  r7, r7, #1
    add  r9, r9, #1
    b    DDP_Col
DDP_NextRow:
    add  r8, r8, #1
    b    DDP_Row
DDP_End:
    pop  {r4-r9, lr}
    bx   lr

// DrawScorePixels(r0=valor, r1=y) - Bono 1
// Dibuja el numero centrado horizontalmente, pixel a pixel.
DrawScorePixels:
    push {r4-r7, lr}
    mov  r6, r1                     // y
    ldr  r5, =digitos_buf
    mov  r4, #0                     // cantidad de digitos
DSP_Split:
    bl   Div10                      // r0 = cociente, r1 = digito
    strb r1, [r5, r4]
    add  r4, r4, #1
    cmp  r0, #0
    bne  DSP_Split

    mov  r0, #(2*PIX_SCALE)         // cada digito ocupa 4 * escala
    mul  r1, r4, r0
    rsb  r7, r1, #(WIDTH/2)         // x inicial = 160 - n * 2 * escala
DSP_Draw:
    subs r4, r4, #1
    blt  DSP_End
    ldrb r0, [r5, r4]               // primero el digito mas significativo
    mov  r1, r7
    mov  r2, r6
    bl   DrawDigitPixels
    add  r7, r7, #(4*PIX_SCALE)
    b    DSP_Draw
DSP_End:
    pop  {r4-r7, lr}
    bx   lr

.ltorg

//===================================================================
// SUBRUTINAS - UTILIDADES
//===================================================================

// Delay(r0 = numero de vueltas) - pausa por conteo
Delay:
    push {r1}
    mov  r1, #0
Delay_Loop:
    add  r1, r1, #1
    cmp  r1, r0
    blt  Delay_Loop
    pop  {r1}
    bx   lr

// Div10(r0 = valor) -> r0 = valor / 10, r1 = valor % 10
// Solo usa r0 y r1: se puede llamar tambien desde las ISR.
Div10:
    mov  r1, r0
    mov  r0, #0
D10_Loop:
    cmp  r1, #10
    blt  D10_End
    sub  r1, r1, #10
    add  r0, r0, #1
    b    D10_Loop
D10_End:
    bx   lr

// NextRandom -> r0 = numero pseudoaleatorio
// Generador lineal congruente sobre 'semilla', mezclado con R8.
NextRandom:
    push {r1-r2}
    ldr  r1, =semilla
    ldr  r0, [r1]
    ldr  r2, =1664525
    mul  r0, r2, r0
    ldr  r2, =1013904223
    add  r0, r0, r2
    add  r0, r0, r8                 // mezclar el contador de cuadros
    str  r0, [r1]
    lsr  r0, r0, #8                 // los bits bajos de un LCG son pobres
    pop  {r1-r2}
    bx   lr

//===================================================================
// SUBRUTINAS - FRUTA
//===================================================================

// GenerateFood - elige una casilla pseudoaleatoria libre para la fruta
// (Parte 5.2). La fruta queda alineada a la cuadricula de 10 x 10 para
// que la serpiente y el automata puedan coincidir con ella.
GenerateFood:
    push {r4-r5, lr}
GF_Retry:
    bl   NextRandom
    and  r4, r0, #(GRID_COLS-1)     // columna 0..31
    lsr  r5, r0, #8
    and  r5, r5, #0xFF
GF_ModY:                            // fila = r5 mod 24
    cmp  r5, #GRID_ROWS
    blt  GF_DoneY
    sub  r5, r5, #GRID_ROWS
    b    GF_ModY
GF_DoneY:
    add  r4, r4, r4, lsl #2
    lsl  r4, r4, #1                 // x = columna * 10
    add  r5, r5, r5, lsl #2
    lsl  r5, r5, #1                 // y = fila * 10

    mov  r0, r4
    mov  r1, r5
    bl   CheckCollisionWithSnake
    cmp  r0, #1
    beq  GF_Retry                   // posicion ocupada, reintentar

    ldr  r2, =fruta_x
    str  r4, [r2]
    ldr  r2, =fruta_y
    str  r5, [r2]

    pop  {r4-r5, lr}
    bx   lr

// CheckCollisionWithSnake(r0=x, r1=y)
// Devuelve: r0 = 1 si (x, y) coincide con la cabeza (R9, R10) o con
// algun segmento vivo de la cola; r0 = 0 si no. Preserva r1-r12.
CheckCollisionWithSnake:
    push {r1-r7, lr}
    mov  r4, r0
    mov  r5, r1

    cmp  r4, r9
    bne  CCWS_Tail
    cmp  r5, r10
    beq  CCWS_Hit

CCWS_Tail:
    ldr  r0, =largo_cola
    ldr  r6, [r0]                   // r6 = n
    ldr  r0, =indice_historial
    ldr  r7, [r0]                   // r7 = indice de la cabeza
    mov  r3, #1
CCWS_Loop:
    cmp  r3, r6
    bgt  CCWS_NoHit
    sub  r0, r7, r3
    and  r0, r0, #0xFF
    ldr  r1, =historial_pos
    add  r1, r1, r0, lsl #3
    ldr  r0, [r1, #0]
    ldr  r1, [r1, #4]
    cmp  r4, r0
    bne  CCWS_Next
    cmp  r5, r1
    beq  CCWS_Hit
CCWS_Next:
    add  r3, r3, #1
    b    CCWS_Loop
CCWS_Hit:
    mov  r0, #1
    pop  {r1-r7, lr}
    bx   lr
CCWS_NoHit:
    mov  r0, #0
    pop  {r1-r7, lr}
    bx   lr

//===================================================================
// SUBRUTINAS - COLISIONES DE LA SERPIENTE
//===================================================================

// CheckCollision_FoodHead
// Caja envolvente entre la cabeza (10 x 10) y la fruta (10 x 10).
// Devuelve: r0 = 1 si hay colision, r0 = 0 si no la hay.
CheckCollision_FoodHead:
    push {r1-r5, lr}

    ldr  r1, =fruta_x
    ldr  r1, [r1]                   // r1 = fruta_x
    ldr  r2, =fruta_y
    ldr  r2, [r2]                   // r2 = fruta_y

    mov  r0, #0

    add  r3, r1, #FOOD_SIZE         // borde derecho de la fruta
    add  r4, r9, #BOX_SIZE          // borde derecho de la cabeza
    add  r5, r2, #FOOD_SIZE         // borde inferior de la fruta

    cmp  r9, r3
    bge  CFH_No
    cmp  r4, r1
    ble  CFH_No
    cmp  r10, r5
    bge  CFH_No
    add  r3, r10, #BOX_SIZE         // borde inferior de la cabeza
    cmp  r3, r2
    ble  CFH_No

    mov  r0, #1
CFH_No:
    pop  {r1-r5, lr}
    bx   lr

// CheckSelfCollision (Parte 3.2)
// Compara la cabeza (R9, R10) con cada segmento de la cola, desde
// i = 1 hasta largo_cola. Se llama despues de guardar la cabeza en
// historial_pos, asi que i = 0 es la propia cabeza y se omite.
// Devuelve: r0 = 1 si la cabeza toca la cola, r0 = 0 si no.
CheckSelfCollision:
    push {r1-r7, lr}
    ldr  r0, =largo_cola
    ldr  r5, [r0]                   // n
    ldr  r0, =indice_historial
    ldr  r6, [r0]                   // indice de la cabeza
    mov  r4, #1                     // i = 1 (primer segmento de cola)
CSC_Loop:
    cmp  r4, r5
    bgt  CSC_NoHit
    sub  r0, r6, r4
    and  r0, r0, #0xFF
    ldr  r3, =historial_pos
    add  r3, r3, r0, lsl #3
    ldr  r0, [r3, #0]               // x del segmento
    ldr  r1, [r3, #4]               // y del segmento
    cmp  r9, r0
    bne  CSC_Next
    cmp  r10, r1
    beq  CSC_Hit
CSC_Next:
    add  r4, r4, #1
    b    CSC_Loop
CSC_Hit:
    mov  r0, #1
    pop  {r1-r7, lr}
    bx   lr
CSC_NoHit:
    mov  r0, #0
    pop  {r1-r7, lr}
    bx   lr

.ltorg

//===================================================================
// SUBRUTINAS - AUTOMATA RIVAL
//===================================================================

//-------------------------------------------------------------------
// MoveBot - estrategia del grupo (Parte 4.3)
//-------------------------------------------------------------------
// 1) Objetivo segun la personalidad (estrategia_bot):
//      0 = Glotona  : la fruta.
//      1 = Cazadora : la casilla que la cabeza del jugador va a pisar
//                     en el cuadro siguiente (cabeza + HUNT_AHEAD *
//                     direccion), para que el jugador choque con ella.
// 2) Voraz por eje dominante: se prueban 4 pasos en orden de
//    preferencia. Primero el eje con mayor distancia al objetivo,
//    luego el otro eje hacia el objetivo, y al final las dos
//    direcciones contrarias.
// 3) Se acepta el primer paso que quede dentro de la pantalla y (si
//    la personalidad esquiva) que no pise a la serpiente. Si ninguno
//    esta libre se usa el primero dentro de la pantalla.
// 4) Se guarda la posicion nueva en bot_x / bot_y y en el historial
//    del automata (para dibujar su cola).
//
// Entradas: bot_x, bot_y, fruta_x, fruta_y, historial de la
//           serpiente; R9-R12 (cabeza y direccion del jugador).
// Salidas:  bot_x, bot_y, bot_indice, bot_historial.
// Paso fijo de BOX_SIZE, solo en x o solo en y. Preserva R4-R12.
//-------------------------------------------------------------------
MoveBot:
    push {r4-r7, lr}
    ldr  r0, =bot_x
    ldr  r4, [r0]                   // r4 = bot_x
    ldr  r0, =bot_y
    ldr  r5, [r0]                   // r5 = bot_y

    // 1) Objetivo (r0, r1)
    ldr  r0, =estrategia_bot
    ldr  r0, [r0]
    cmp  r0, #0
    bne  MB_Hunter
    ldr  r0, =fruta_x               // Glotona: ir por la fruta
    ldr  r0, [r0]
    ldr  r1, =fruta_y
    ldr  r1, [r1]
    b    MB_Target
MB_Hunter:
    mov  r2, #(BOX_SIZE*HUNT_AHEAD) // Cazadora: delante de la cabeza
    mla  r0, r11, r2, r9
    mla  r1, r12, r2, r10
    cmp  r0, #0                     // acotar el objetivo a la pantalla
    movlt r0, #0
    ldr  r2, =BOX_MAX_X
    cmp  r0, r2
    movgt r0, r2
    cmp  r1, #0
    movlt r1, #0
    ldr  r2, =BOX_MAX_Y
    cmp  r1, r2
    movgt r1, r2
MB_Target:

    // 2) Distancias y sentido de los pasos (si la distancia es 0 se
    //    toma +BOX_SIZE; las opciones contrarias cubren el borde)
    subs r2, r0, r4                 // r2 = dx
    mov  r6, #BOX_SIZE              // r6 = paso en x hacia el objetivo
    rsblt r6, r6, #0
    rsblt r2, r2, #0                // r2 = |dx|
    subs r3, r1, r5                 // r3 = dy
    mov  r7, #BOX_SIZE              // r7 = paso en y hacia el objetivo
    rsblt r7, r7, #0
    rsblt r3, r3, #0                // r3 = |dy|

    // Lista de 4 pasos (dx, dy) en orden de preferencia
    ldr  r0, =bot_opciones
    mov  r1, #0
    cmp  r2, r3
    blt  MB_VertFirst
    str  r6, [r0, #0]               // 1: x hacia el objetivo
    str  r1, [r0, #4]
    str  r1, [r0, #8]               // 2: y hacia el objetivo
    str  r7, [r0, #12]
    rsb  r2, r7, #0
    str  r1, [r0, #16]              // 3: y contraria
    str  r2, [r0, #20]
    rsb  r2, r6, #0
    str  r2, [r0, #24]              // 4: x contraria
    str  r1, [r0, #28]
    b    MB_TryOptions
MB_VertFirst:
    str  r1, [r0, #0]               // 1: y hacia el objetivo
    str  r7, [r0, #4]
    str  r6, [r0, #8]               // 2: x hacia el objetivo
    str  r1, [r0, #12]
    rsb  r2, r6, #0
    str  r2, [r0, #16]              // 3: x contraria
    str  r1, [r0, #20]
    rsb  r2, r7, #0
    str  r1, [r0, #24]              // 4: y contraria
    str  r2, [r0, #28]

    // 3) Elegir el primer paso aceptable
MB_TryOptions:
    mov  r6, #0                     // k = opcion actual
    mvn  r7, #0                     // r7 = -1: aun no hay respaldo
MB_Loop:
    cmp  r6, #4
    bge  MB_UseFallback
    ldr  r2, =bot_opciones
    add  r2, r2, r6, lsl #3
    ldr  r0, [r2, #0]
    ldr  r1, [r2, #4]
    add  r0, r4, r0                 // x candidata
    add  r1, r5, r1                 // y candidata

    cmp  r0, #0                     // dentro de la pantalla?
    blt  MB_Next
    ldr  r2, =BOX_MAX_X
    cmp  r0, r2
    bgt  MB_Next
    cmp  r1, #0
    blt  MB_Next
    ldr  r2, =BOX_MAX_Y
    cmp  r1, r2
    bgt  MB_Next

    cmp  r7, #0
    movlt r7, r6                    // primera opcion dentro de la pantalla

    // La glotona solo esquiva si GLOTONA_ESQUIVA = 1
    ldr  r2, =estrategia_bot
    ldr  r2, [r2]
    cmp  r2, #0
    bne  MB_CheckSnake
    mov  r2, #GLOTONA_ESQUIVA
    cmp  r2, #0
    beq  MB_Commit
MB_CheckSnake:
    mov  r3, r0                     // CheckCollisionWithSnake preserva r1-r7
    bl   CheckCollisionWithSnake
    cmp  r0, #0
    mov  r0, r3
    beq  MB_Commit                  // casilla libre
MB_Next:
    add  r6, r6, #1
    b    MB_Loop

MB_UseFallback:
    cmp  r7, #0                     // siempre hay al menos una dentro,
    blt  MB_End                     // pero por si acaso no se mueve
    ldr  r2, =bot_opciones
    add  r2, r2, r7, lsl #3
    ldr  r0, [r2, #0]
    ldr  r1, [r2, #4]
    add  r0, r4, r0
    add  r1, r5, r1

    // 4) Guardar la posicion nueva y registrarla en el historial
MB_Commit:
    ldr  r2, =bot_x
    str  r0, [r2]
    ldr  r2, =bot_y
    str  r1, [r2]
    ldr  r2, =bot_indice
    ldr  r3, [r2]
    add  r3, r3, #1
    and  r3, r3, #0xFF
    str  r3, [r2]
    ldr  r2, =bot_historial
    add  r2, r2, r3, lsl #3
    str  r0, [r2, #0]
    str  r1, [r2, #4]
MB_End:
    pop  {r4-r7, lr}
    bx   lr

//-------------------------------------------------------------------
// BotEatFood - si la personalidad es glotona y el automata esta sobre
// la fruta, crece una casilla y se genera una fruta nueva.
//-------------------------------------------------------------------
BotEatFood:
    push {r4, lr}
    ldr  r0, =estrategia_bot
    ldr  r0, [r0]
    cmp  r0, #0
    bne  BEF_End                    // la cazadora no come
    ldr  r0, =bot_x
    ldr  r0, [r0]
    ldr  r1, =fruta_x
    ldr  r1, [r1]
    cmp  r0, r1
    bne  BEF_End
    ldr  r0, =bot_y
    ldr  r0, [r0]
    ldr  r1, =fruta_y
    ldr  r1, [r1]
    cmp  r0, r1
    bne  BEF_End

    ldr  r0, =bot_largo
    ldr  r1, [r0]
    cmp  r1, #BOT_MAX_LEN
    addlt r1, r1, #1
    str  r1, [r0]
    bl   GenerateFood
BEF_End:
    pop  {r4, lr}
    bx   lr

//-------------------------------------------------------------------
// ResetBotCola - deja al automata sin cola y registra su posicion
// actual en su historial. Se llama siempre despues de ResetBot.
//-------------------------------------------------------------------
ResetBotCola:
    push {r4, lr}
    ldr  r0, =bot_largo
    mov  r1, #0
    str  r1, [r0]
    ldr  r0, =bot_indice
    ldr  r1, [r0]
    ldr  r4, =bot_historial
    add  r4, r4, r1, lsl #3
    ldr  r0, =bot_x
    ldr  r0, [r0]
    str  r0, [r4, #0]
    ldr  r0, =bot_y
    ldr  r0, [r0]
    str  r0, [r4, #4]
    pop  {r4, lr}
    bx   lr

//-------------------------------------------------------------------
// DrawBotTail(r2=color) - dibuja (o borra) la cola del automata
//-------------------------------------------------------------------
DrawBotTail:
    push {r4-r7, lr}
    mov  r7, r2                     // color
    ldr  r0, =bot_largo
    ldr  r4, [r0]                   // n
    ldr  r0, =bot_indice
    ldr  r5, [r0]                   // indice de la cabeza del automata
    mov  r6, #1
DBT_Loop:
    cmp  r6, r4
    bgt  DBT_End
    sub  r0, r5, r6
    and  r0, r0, #0xFF
    ldr  r3, =bot_historial
    add  r3, r3, r0, lsl #3
    ldr  r0, [r3, #0]
    ldr  r1, [r3, #4]
    mov  r2, r7
    bl   DrawSquare
    add  r6, r6, #1
    b    DBT_Loop
DBT_End:
    pop  {r4-r7, lr}
    bx   lr

//-------------------------------------------------------------------
// CheckHeadVsBotTail - la cabeza del jugador (R9, R10) toca algun
// segmento de la cola del automata?
// Devuelve: R0 = 1 si hay colision, R0 = 0 si no.
//-------------------------------------------------------------------
CheckHeadVsBotTail:
    push {r1-r7, lr}
    ldr  r0, =bot_largo
    ldr  r4, [r0]
    ldr  r0, =bot_indice
    ldr  r5, [r0]
    mov  r6, #1
CHVBT_Loop:
    cmp  r6, r4
    bgt  CHVBT_NoHit
    sub  r0, r5, r6
    and  r0, r0, #0xFF
    ldr  r3, =bot_historial
    add  r3, r3, r0, lsl #3
    ldr  r0, [r3, #0]
    ldr  r1, [r3, #4]
    cmp  r9, r0
    bne  CHVBT_Next
    cmp  r10, r1
    beq  CHVBT_Hit
CHVBT_Next:
    add  r6, r6, #1
    b    CHVBT_Loop
CHVBT_Hit:
    mov  r0, #1
    pop  {r1-r7, lr}
    bx   lr
CHVBT_NoHit:
    mov  r0, #0
    pop  {r1-r7, lr}
    bx   lr

.ltorg

//-------------------------------------------------------------------
// CheckBotVsSnakeBody - YA IMPLEMENTADA. NO MODIFICAR.
//-------------------------------------------------------------------
// Compara (bot_x, bot_y) contra la cabeza (R9, R10) y contra cada
// segmento vivo de historial_pos.
// Devuelve: R0 = 1 si hay colision, R0 = 0 si no la hay.
//-------------------------------------------------------------------
CheckBotVsSnakeBody:
    push {r1-r7, lr}

    ldr  r0, =bot_x
    ldr  r4, [r0]                   // r4 = bot_x
    ldr  r0, =bot_y
    ldr  r5, [r0]                   // r5 = bot_y

    // Comparar contra la CABEZA
    cmp  r4, r9
    bne  CBVSB_CheckTail
    cmp  r5, r10
    beq  CBVSB_Hit

CBVSB_CheckTail:
    // Comparar contra cada segmento de la COLA
    ldr  r0, =largo_cola
    ldr  r6, [r0]                   // r6 = n
    ldr  r0, =indice_historial
    ldr  r7, [r0]                   // r7 = indice actual de la cabeza
    mov  r3, #1                     // i = 1 (primer segmento de cola)

CBVSB_Loop:
    cmp  r3, r6
    bgt  CBVSB_NoHit

    sub  r0, r7, r3
    and  r0, r0, #0xFF              // indice circular
    ldr  r1, =historial_pos
    add  r1, r1, r0, lsl #3
    ldr  r0, [r1, #0]               // x del segmento
    ldr  r1, [r1, #4]               // y del segmento

    cmp  r4, r0
    bne  CBVSB_Next
    cmp  r5, r1
    beq  CBVSB_Hit

CBVSB_Next:
    add  r3, r3, #1
    b    CBVSB_Loop

CBVSB_Hit:
    mov  r0, #1
    pop  {r1-r7, lr}
    bx   lr

CBVSB_NoHit:
    mov  r0, #0
    pop  {r1-r7, lr}
    bx   lr

//-------------------------------------------------------------------
// CheckHeadVsBot - YA IMPLEMENTADA. NO MODIFICAR.
//-------------------------------------------------------------------
// Caja envolvente entre la cabeza (R9, R10) y el automata rival
// (bot_x, bot_y), ambos cuadrados de BOX_SIZE por BOX_SIZE.
// Devuelve: R0 = 1 si hay colision (fin de partida), R0 = 0 si no.
//-------------------------------------------------------------------
CheckHeadVsBot:
    push {r1-r5, lr}

    ldr  r0, =bot_x
    ldr  r1, [r0]                   // r1 = bot_x
    ldr  r0, =bot_y
    ldr  r2, [r0]                   // r2 = bot_y

    mov  r0, #0                     // suponer que no hay colision

    add  r3, r1, #BOX_SIZE          // borde derecho del automata
    add  r4, r9, #BOX_SIZE          // borde derecho de la cabeza

    cmp  r9, r3
    bge  CHVB_End                   // la cabeza esta a la derecha: no hay
    cmp  r4, r1
    ble  CHVB_End                   // la cabeza esta a la izquierda: no hay

    add  r3, r2, #BOX_SIZE          // borde inferior del automata
    add  r5, r10, #BOX_SIZE         // borde inferior de la cabeza

    cmp  r10, r3
    bge  CHVB_End
    cmp  r5, r2
    ble  CHVB_End

    mov  r0, #1                     // hay colision

CHVB_End:
    pop  {r1-r5, lr}
    bx   lr

//-------------------------------------------------------------------
// ResetBot - YA IMPLEMENTADA. NO MODIFICAR.
//-------------------------------------------------------------------
// Devuelve el automata rival a la posicion fija (200, 120). Se llama
// cuando CheckBotVsSnakeBody devuelve 1.
//-------------------------------------------------------------------
ResetBot:
    push {r0-r1, lr}
    ldr  r0, =bot_x
    mov  r1, #200
    str  r1, [r0]
    ldr  r0, =bot_y
    mov  r1, #120
    str  r1, [r0]
    pop  {r0-r1, lr}
    bx   lr

.ltorg

/*======================================================================
   BLOQUE 5 - RUTINAS DE INTERRUPCION
  ======================================================================*/

/*----------------------------------------------------------------------
   SET_IRQs - registra cada identificador de interrupcion en el GIC
  ----------------------------------------------------------------------*/
SET_IRQs:
    PUSH {LR}
    MOV  R0, #72                    // 72 = Temporizador de intervalos 0
    BL   CONFIG_GIC
    MOV  R0, #73                    // 73 = Pulsadores KEY0..KEY3
    BL   CONFIG_GIC
    MOV  R0, #79                    // 79 = Teclado PS/2
    BL   CONFIG_GIC
    POP  {PC}

/*----------------------------------------------------------------------
   CONFIG_INTERVAL_TIMER - interrupcion cada 1 s en modo continuo
   carga = 100 000 000 - 1 = 0x05F5E0FF (reloj de 100 MHz)
  ----------------------------------------------------------------------*/
CONFIG_INTERVAL_TIMER:
    PUSH {LR}
    LDR  R0, =TIMER_BASE
    LDR  R1, =0xE0FF
    STR  R1, [R0, #0x08]            // Carga baja
    LDR  R1, =0x05F5
    STR  R1, [R0, #0x0C]            // Carga alta
    MOV  R1, #0b111                 // START = 1, CONT = 1, ITO = 1
    STR  R1, [R0, #0x04]            // Control
    POP  {PC}

/*----------------------------------------------------------------------
   CONFIG_KEYS - habilitar las interrupciones de KEY0..KEY3
  ----------------------------------------------------------------------*/
CONFIG_KEYS:
    PUSH {LR}
    LDR  R0, =KEY_BASE
    MOV  R1, #0xF
    STR  R1, [R0, #0x0C]            // Limpiar la captura de flanco
    STR  R1, [R0, #0x08]            // Mascara: habilitar los 4 pulsadores
    POP  {PC}

/*----------------------------------------------------------------------
   CONFIG_PS2 - habilitar la interrupcion por recepcion (Parte 2.1)
  ----------------------------------------------------------------------*/
CONFIG_PS2:
    PUSH {LR}
    LDR  R0, =PS2_BASE              // Base del controlador PS/2 (0xFF200100)
CPS2_Flush:                         // vaciar bytes viejos de la cola
    LDR  R1, [R0]
    TST  R1, #0x8000                // RVALID
    BNE  CPS2_Flush
    MOV  R1, #1                     // Bit 0 (RI) = 1: interrumpir al recibir
    STR  R1, [R0, #4]               // Registro de control
    POP  {PC}

/*----------------------------------------------------------------------
   CONFIG_GIC y CONFIG_INTERRUPT - controlador de interrupciones (GIC)
  ----------------------------------------------------------------------*/
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

/*----------------------------------------------------------------------
   SERVICE_IRQ - despachador de interrupciones
   CORREGIDO: se guardan R0-R12 (antes solo R0-R7). R8-R12 son los
   registros globales del MainLoop (contador, cabeza y direccion); si
   una ISR los tocara, el juego se corromperia sin aviso.
   Un identificador desconocido (p. ej. 1023, interrupcion espuria) ya
   no congela el programa: se ignora.
  ----------------------------------------------------------------------*/
.global SERVICE_IRQ
SERVICE_IRQ:
    PUSH {R0-R12, LR}

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

    // Identificador desconocido: se ignora
IRQ_Unexpected:

EXIT_IRQ:
    STR  R5, [R4, #0x10]            // ICCEOIR: fin de la interrupcion
    POP  {R0-R12, LR}
    SUBS PC, LR, #4                 // Retorno de interrupcion

/*----------------------------------------------------------------------
   TIMER_ISR - se ejecuta cada segundo
     1. Limpia la bandera TO.
     2. Muestra 'puntaje' en los LED rojos y en HEX3..HEX0
        (binario -> BCD -> patron de 7 segmentos).
     3. Incrementa 'Contador' (depuracion).
  ----------------------------------------------------------------------*/
.global TIMER_ISR
TIMER_ISR:
    PUSH {R4-R7, LR}
    LDR  R0, =TIMER_BASE
    MOV  R1, #0
    STR  R1, [R0]                   // Limpiar la bandera TO

    // Mostrar el puntaje en los LED rojos
    LDR  R0, =puntaje
    LDR  R1, [R0]
    LDR  R0, =LEDR_BASE
    STR  R1, [R0]

    // Mostrar el puntaje en HEX3..HEX0: 4 digitos decimales
    LDR  R0, =puntaje
    LDR  R0, [R0]
    MOV  R4, #0                     // patron acumulado
    MOV  R5, #0                     // desplazamiento del digito (0, 8, 16, 24)
    LDR  R6, =tabla_7seg
TISR_Digit:
    BL   Div10                      // R0 = cociente, R1 = digito BCD
    LDRB R2, [R6, R1]               // patron de 7 segmentos
    ORR  R4, R4, R2, LSL R5
    ADD  R5, R5, #8
    CMP  R5, #32
    BLT  TISR_Digit
    LDR  R0, =HEX3_0_BASE
    STR  R4, [R0]

    // Contador interno (depuracion)
    LDR  R0, =Contador
    LDR  R1, [R0]
    ADD  R1, R1, #1
    STR  R1, [R0]

    POP  {R4-R7, LR}
    BX   LR

/*----------------------------------------------------------------------
   KEY_ISR - rutina de servicio de los pulsadores
     KEY0: empezar / reiniciar (igual que Espacio o Enter)
     KEY1: pausa
     KEY3: conmutar la personalidad del automata (Parte 4)
  ----------------------------------------------------------------------*/
.global KEY_ISR
KEY_ISR:
    PUSH {R4, LR}
    LDR  R0, =KEY_BASE
    LDR  R4, [R0, #0xC]             // Captura de flanco
    MOV  R2, #0xF
    STR  R2, [R0, #0xC]             // Limpiar todas las banderas

CHECK_KEY0:
    TST  R4, #0x1
    BEQ  CHECK_KEY1
    LDR  R0, =tecla_inicio
    MOV  R1, #1
    STR  R1, [R0]

CHECK_KEY1:
    TST  R4, #0x2
    BEQ  CHECK_KEY3
    LDR  R0, =pausa
    LDR  R1, [R0]
    EOR  R1, R1, #1
    STR  R1, [R0]

CHECK_KEY3:
    TST  R4, #0x8
    BEQ  END_KEY_ISR
    LDR  R0, =estrategia_bot
    LDR  R1, [R0]
    EOR  R1, R1, #1                 // 0 = glotona, 1 = cazadora
    STR  R1, [R0]
    BL   ShowStrategy

END_KEY_ISR:
    POP  {R4, LR}
    BX   LR

/*----------------------------------------------------------------------
   ShowStrategy - muestra la personalidad del automata:
     HEX5 = 'G' o 'C', HEX4 = 0 o 1
  ----------------------------------------------------------------------*/
ShowStrategy:
    LDR  R0, =estrategia_bot
    LDR  R0, [R0]
    CMP  R0, #0
    MOVEQ R1, #0x3D                 // 'G'
    MOVNE R1, #0x39                 // 'C'
    MOVEQ R2, #0x3F                 // '0'
    MOVNE R2, #0x06                 // '1'
    ORR  R1, R2, R1, LSL #8
    LDR  R0, =HEX5_4_BASE
    STR  R1, [R0]
    BX   LR

/*----------------------------------------------------------------------
   PS2_ISR - rutina de servicio del teclado PS/2
   - Flechas (E0 + codigo): escriben dir_pendiente_x / dir_pendiente_y.
   - Espacio / Enter: tecla_inicio = 1.
   - Codigo de liberacion F0: se ignora el byte siguiente, asi soltar
     una tecla no produce ningun efecto (bonificacion de la plantilla).
   No escribe en R11 ni R12: el filtro de 180 grados esta en el MainLoop.
  ----------------------------------------------------------------------*/
.global PS2_ISR
PS2_ISR:
    PUSH {R0-R4, LR}

    LDR  R0, =PS2_BASE              // Base del teclado PS/2
    LDR  R1, [R0]                   // Registro de datos (leerlo limpia la IRQ)
    TST  R1, #0x8000                // Bit RVALID: hay dato valido?
    BEQ  PS2_ISR_End

    AND  R0, R1, #0xFF              // byte recibido

    // Prefijo de liberacion 0xF0: ignorar el siguiente codigo
    CMP  R0, #0xF0
    BNE  PS2_Check_Release
    LDR  R1, =bandera_f0_ps2
    MOV  R2, #1
    STR  R2, [R1]
    B    PS2_ISR_End

PS2_Check_Release:
    LDR  R1, =bandera_f0_ps2
    LDR  R2, [R1]
    CMP  R2, #1
    BNE  PS2_Check_E0
    MOV  R2, #0
    STR  R2, [R1]                   // limpiar F0
    LDR  R1, =bandera_e0_ps2
    STR  R2, [R1]                   // y E0 (secuencia E0 F0 xx)
    B    PS2_ISR_End

    // Manejo de la bandera E0 (prefijo de tecla extendida)
PS2_Check_E0:
    LDR  R1, =bandera_e0_ps2
    LDR  R2, [R1]
    CMP  R2, #1
    BEQ  PS2_Handle_Extended

    // Byte normal: es el prefijo 0xE0?
    CMP  R0, #0xE0
    BNE  PS2_Check_Start
    MOV  R2, #1
    STR  R2, [R1]
    B    PS2_ISR_End

    // Espacio o Enter: pedir inicio / reinicio
PS2_Check_Start:
    CMP  R0, #KEY_SPACE
    CMPNE R0, #KEY_ENTER
    BNE  PS2_ISR_End
    LDR  R1, =tecla_inicio
    MOV  R2, #1
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
    BNE  PS2_Check_KeypadEnter
    LDR  R3, =dir_pendiente_x
    MOV  R4, #1
    STR  R4, [R3]
    LDR  R3, =dir_pendiente_y
    MOV  R4, #0
    STR  R4, [R3]
    B    PS2_ISR_End

    // Enter del teclado numerico (E0 5A) tambien inicia
PS2_Check_KeypadEnter:
    CMP  R0, #KEY_ENTER
    BNE  PS2_ISR_End
    LDR  R3, =tecla_inicio
    MOV  R4, #1
    STR  R4, [R3]

PS2_ISR_End:
    POP  {R0-R4, LR}
    BX   LR

/*----------------------------------------------------------------------
   MANEJADORES DE EXCEPCIONES - bucles de captura
  ----------------------------------------------------------------------*/
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

.ltorg

/*======================================================================
   BLOQUE 6 - SECCION .data UNIFICADA
  ======================================================================*/
.data
.align 2

// Variables de la plantilla de interrupciones
Contador:          .word 0      // Pulsos contados del temporizador

// Estado de la partida
estado_juego:      .word 0      // 0 = jugando | 1 = fin de partida
puntaje:           .word 0      // Frutas comidas por el jugador
pausa:             .word 0      // 1 = juego en pausa (KEY1)
tecla_inicio:      .word 0      // 1 = se oprimio Espacio / Enter / KEY0

// Sincronizacion entre PS2_ISR y el MainLoop
bandera_e0_ps2:    .word 0      // 1 cuando el byte anterior fue 0xE0
bandera_f0_ps2:    .word 0      // 1 cuando el byte anterior fue 0xF0
dir_pendiente_x:   .word 1      // CORREGIDO: 0 detenia la serpiente al arrancar
dir_pendiente_y:   .word 0

// Variables de la fruta
fruta_x:           .word 0
fruta_y:           .word 0
semilla:           .word 0x1234567  // semilla del generador aleatorio

// Variables de la serpiente del jugador
largo_cola:        .word 4      // longitud inicial de la cola
indice_historial:  .word 0      // indice circular dentro de historial_pos

// Variables del automata rival
bot_x:             .word 200    // x inicial del automata
bot_y:             .word 120    // y inicial del automata
estrategia_bot:    .word 0      // 0 = glotona | 1 = cazadora (KEY3)
velocidad_bot:     .word 1      // pasos por cuadro (Bono 2: 2 si puntaje > 10)
bot_largo:         .word 0      // longitud de la cola del automata
bot_indice:        .word 0      // indice circular dentro de bot_historial
bot_opciones:      .space (4 * 8)   // pasos candidatos de MoveBot

// Tabla de 8 colores para la cabeza (se recorre ciclicamente).
// Se cambiaron el amarillo (color del automata) y el gris (color de
// la cola) para que la cabeza no se confunda con ellos.
tabla_colores:
    .word 0xF800    // 0: rojo
    .word 0x07E0    // 1: verde
    .word 0x001F    // 2: azul
    .word 0x801F    // 3: violeta
    .word 0xF81F    // 4: magenta
    .word 0x07FF    // 5: cian
    .word 0xFFFF    // 6: blanco
    .word 0xAFE5    // 7: verde lima

// Fuente de 3x5 pixeles para el Bono 1 (bit 14 = esquina superior izq.)
fuente_digitos:
    .word 0x7B6F, 0x2C97, 0x73E7, 0x73CF, 0x5BC9
    .word 0x79CF, 0x79EF, 0x7249, 0x7BEF, 0x7BCF

// Patrones de 7 segmentos de los digitos 0..9
tabla_7seg:
    .byte 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F

digitos_buf:       .space 12

// Textos (buffer de caracteres)
txt_titulo:        .asciz "S N A K E   A R M"
txt_curso:         .asciz "Parcial 3 - Arquitectura de Computadores UIS 2026"
txt_autores:       .asciz "Autores: Sandoval - Gonzalez"
txt_empezar:       .asciz "Presione Espacio o Enter para empezar"
txt_controles1:    .asciz "Flechas: mover   KEY1: pausa"
txt_controles2:    .asciz "KEY3: cambiar automata (G = glotona, C = cazadora)"
txt_game_over:     .asciz "G A M E   O V E R"
txt_puntaje:       .asciz "Puntaje"
txt_reiniciar:     .asciz "Presione Espacio o Enter para jugar de nuevo"

// Arreglos circulares de posiciones
// (256 entradas de 8 bytes: 4 para x y 4 para y)
.align 4
historial_pos:     .space (256 * 8)
bot_historial:     .space (256 * 8)

.end
