export type Fila = { texto: string }

declare module 'claude-code' {
  interface PluginState {
    'multi-ia-orquestador': {
      datos: Shaped<{
        modo?: string
        eventos?: { f: string; t: string; d: string; x: string; m: string; k: string; tok: number; s: number }[]
        calidad?: string
        manual?: { codex: { modelo: string; esfuerzo: string }; agy: { modelo: string } }
        horas?: { h: number; c: number; d: number }[]
        deleg_total?: number
        deleg_n?: number
        claude_costo?: number
        ses_deleg?: number
        ses_n?: number
        ses_costo?: number
        glob?: { ses: number; tin: number; tout: number; hoy: number; semana: number; mes: number; codex: number; agy: number; errores: number; sin_dato: number }
        presup?: { tope: number; hoy: number; aviso: number; cache: number; arena: string }
        activas?: number
        max?: number
        tarjetas: { nombre: string; ventanas: { v: string; usado: number; reinicia?: string; origen?: string }[] }[]
        pesada?: { msgs: number; ctx: number } | null
      }>
      actualizado: Shaped<string>
      latido: Shaped<{ rap: number; cupos: number; leyendo: boolean; err: string; movs: { f: string; t: string }[] }>
      abierto: Shaped<boolean>
      ctrl: Shaped<boolean>
      filtro: Shaped<string>
      vista: Shaped<{ rango: '24h' | '7d' | '30d'; seccion: string; ocultas: string[]; plegadas: string[]; q: string; cp: number; filtro: string }>
      intensidad: Shaped<{ g: string; v: string; origen: string; chatId: string; msg: string; t: number }>
      reinicio: Shaped<{ paso: 'idle' | 'revisando' | 'confirmar' | 'corriendo'; modo: 'claude' | 'orquestador'; msg: string }>
      chats: Shaped<{ j: unknown | null; t: number; leyendo: boolean; err: string; sel: string; est: string; fmotor: string; fest: string; msg: string }>
    }
  }
}
