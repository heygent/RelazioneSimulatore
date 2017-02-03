---
lang: it
author: Emanuele Gentiletti
---

# Simulatore

## Introduzione

Nella realizzazione del simulatore si è tenuto conto di questi criteri:

* Modularità 
* Riutilizzo di strumenti esistenti, sia prodotti internamente che presi da
  librerie esterne
* Velocità di sviluppo
* Estensibilità

Python aiuta a seguire questi criteri: la tipizzazione dinamica permette di
far interoperare le componenti facilmente. In particolar modo, nel simulatore
si hanno interfacce comuni per l'invio dei messaggi ai diversi componenti,
siano essi nodi o bus, permettendo un trattamento agnostico rispetto al
funzionamento da componente a componente. In particolare, l'unico requisito di
funzionamento di un'entità all'interno della rete è la presenza di un
metodo, `send_process`, che rappresenta la comunicazione di un messaggio a un
componente.

Nell'implementazione del protocollo si è tenuto in conto degli stessi criteri.
Quando possibile, si è optato per utilizzare soluzioni di emulazione del
comportamento dell'entità utente del protocollo, in modo da evitare quanto più
possibile bug relativi a un'implementazione di basso livello e rendere il tutto
il più breve e mantenibile possibile.

\pagebreak

## Strumenti

Gli strumenti principali utilizzati nello sviluppo del simulatore sono:

* **`simpy`**, libreria di simulazione
* **`networkx`**, libreria di gestione di grafi.
* **`logging`**, modulo parte della libreria standard di Python
* **`SortedContainers`**, libreria contenente strutture dati che preservano
  l'ordine naturale degli elementi contenuti, utilizzato nella gestione degli
  indirizzi nell'implementazione del protocollo.

### `simpy`

Simpy fornisce un ambiente di simulazione discreta che pone alla base del suo
funzionamento i generatori, funzionalità del linguaggio Python uguale a quello
che altri linguaggi chiamano coroutine. Un generatore è dunque una funzione che
può sospendersi, restituendo o meno un valore, e il cui corso può essere
ripreso in seguito nel programma. I generatori, all'interno di simpy, vengono
utilizzati per modellare i processi, che durante la loro esecuzione
"restituiscono", o in gergo più pythonico, producono eventi.

Quando un generatore associato a un processo produce un evento, il processo
sospende la sua esecuzione. L'esecuzione del processo riprenderà quando
l'evento da esso prodotto avrà uno stato di `triggered`, o in esecuzione.

Il seguente è un esempio di generatore utilizzabile da un processo:

```python
def waiter(env, pid):
    print(f"Io sono {pid}, aspetto 10 tic ed esco")
    yield env.timeout(10)
    print(f"{pid} ha terminato.")
```

Simpy gestisce la sospensione e la ripresa d'esecuzione dei processi,
utilizzando un heap il cui ordine è basato sul tempo di esecuzione pianificato
per l'evento. Quando un evento "scatta", simpy riprende in ordine l'esecuzione
dei processi in attesa di questo.

Gli stessi processi sono considerati eventi da simpy. Un processo che produce
un riferimento a un altro processo richiede di attendere il termine di questo.

Gli eventi possono inoltre avere un valore, contenuto nel loro attributo
`value`, il quale viene stabilito da chi fa scattare l'evento, ad esempio
tramite l'evento `ev.succeed(self, value)`. Questo è un meccanismo che permette
di scambiare messaggi tra processi.

Oltre a queste funzionalità base di simulazione, simpy fornisce altre entità
utili alla definizione di simulazioni, quali code e risorse. In alcuni casi
questi strumenti sono risultati adeguati, mentre in altri è stato necessario
ricorrere a soluzioni prodotte in proprio per ottenere un risultato migliore.


#### Creazione dei processi

Creare processi con simpy è un passaggio tedioso e facilmente dimenticabile:

```python
env = simpy.Environment()
env.process(waiter(env, "Pippo"))
```

Per semplificare l'operazione, è stato creato il seguente decoratore,
`simpy_process`:

```python
def simpy_process(process_fn, env_attr='env'):

    @wraps(process_fn)
    def wrapper(self, *args, **kwargs):
        return getattr(self, env_attr).process(
            process_fn(self, *args, **kwargs)
        )

    return wrapper
```

La maggior parte dei generatori che contengono il codice eseguito dai processi
si trovano in classi dove l'attributo `env`, per convenzione, contiene
l'ambiente della simulazione. Il decoratore sfrutta questa proprietà, creando
un wrapper per sostituire il metodo con uno che crei direttamente un processo,
utilizzando il generatore e `self.env` come ambiente:

```python
class Waiter:
    def __init__(self, env, name, wait_time):
        self.env = env
        self.name = name
        self.wait_time = wait_time

    @simpy_process
    def run(self):
        env = self.env

        print(f"[{env.now}] {self.name} starts")
        yield env.timeout(self.wait_time)
        print(f"[{env.now}] {self.name} ends")

env = simpy.Environment()
my_process = SomeProcess(env, "P1", 10).run()
assert isinstance(my_process, simpy.Process)
env.run()

"""
Output:

[0] P1 starts
[10] P1 ends
"""
```

#### Creazione degli eventi

La gestione di eventi ricorrenti in simpy richiede un passaggio ridondante,
ovvero ricreare un nuovo evento ogni volta che questo viene attivato.

```python

ring_bell_ev = env.event()

def ringer():
    global ring_bell_ev
    while True:
        yield env.timeout(10)
        old_ring_ev, ring_bell_ev = ring_bell_ev, env.event()
        old_ring_ev.succeed()

def waiter():
    while True:
        yield ring_bell_ev
        print(f"Bell rang at {env.now})


```

Per evitare di dover eseguire questa operazione di volta in volta sono state
create due utilità, ispirate alle interfacce `pthread`: `ConditionVar` e
`BroadcastConditionVar`.

Queste sono classi che contengono un metodo, `wait(self)`, che restituiscono un
evento legato all'avvenimento di una determinata condizione. Allo scattare
della condizione, l'utente può risvegliare uno o tutti i processi in attesa,
utilizzando i metodi `signal(self, value)` o `broadcast(self, value)`. L'evento
restituito da `wait`, al suo scattare, avrà il valore specificato in `value`.
`ConditionVar` è implementato tramite una coda di eventi.

`BroadcastConditionVar` supporta invece solo la segnalazione a tutti i
processi, ma è più efficiente. Il funzionamento di `BroadcastConditionVar`
è creare un evento, che viene restituito ai processi quando viene chiamato
`wait`. Quando l'evento viene fatto scattare con `broadcast`, questo viene
sostituito con uno nuovo.

Inoltre, `BroadcastConditionVar` supporta l'uso di callback, che vengono
gestite direttamente dagli eventi di `simpy`. Allo scattare di un evento, le
funzioni contenuto nell'attributo `callbacks` di un evento vengono chiamate da
simpy, con l'evento stesso come argomento. `BroadcastConditionVar` contiene
anch'esso un attributo `callbacks`, che vengono aggiunte alla liste delle
funzioni di callback degli eventi che restituisce.

```python
class BroadcastConditionVar:

    def __init__(self, env, callbacks=None):
        self.env = env
        self.callbacks = callbacks or []
        self._signal_ev = self.env.event()

    def wait(self):
        return self._signal_ev

    def broadcast(self, value=None):
        signal_ev, self._signal_ev = self._signal_ev, self.env.event()
        signal_ev.callbacks.extend(self.callbacks)
        signal_ev.succeed(value)
```

### `networkx`

Networkx è una libreria di gestione dei grafi. Viene utilizzata sia
nell'implementazione del protocollo, sia nel simulatore, dove i collegamenti
tra le varie entità sono gestiti in maniera centralizzata tramite un grafo.
Questo permette di lasciare il compito di creare un'interfaccia di
configurazione della simulazione alla libreria: infatti, per creare una
configurazione di rete, si creano i vari componenti, per poi creare degli archi
all'interno del grafo centrale che collegano questi. Per conoscere le loro
connessioni, le componenti, di volta in volta, consultano lo stesso grafo.

La libreria offre funzioni comode per creare archi all'interno di un grafo,
come `add_path` e `add_star`.

### `logging`

Il modulo `logging` fa parte della libreria standard di Python, e viene usato
estensivamente per informare del comportamento della simulazione, sia a livello
d'infrastruttura di base, che di protocollo. Sfortunatamente, `logging` non
permette di creare oggetti `logger` a cui è associato un determinato formato per
il log. Questa operazione deve essere fatta sugli `handler`, ovvero degli
oggetti il cui compito è prendere le informazioni raccolte dal logger e
dirigerele in un flusso di output o in un file. Per questa ragione il
simulatore mette a disposizione funzioni che si occupino di configurare questi.


### Convenzioni dei nomi

Nell'uso delle librerie, si è scelto di usare le seguenti convenzioni per
chiarire l'entità delle variabili:

Suffisso            Tipo
------------------  ------------------------------------------------------
`ev`                `simpy.Event`
`proc` o `process`  `simpy.Process`
`graph`             `networkx.Graph`
`cond`              `utils.ConditionVar` o `utils.BroadcastConditionVar`

Ad esempio, una variabile chiamata `timer_end_ev` sarà di tipo `simpy.Event`.

\pagebreak

## Architettura

Nel seguire i criteri discussi prima, si è scelto di utilizzare un'architettura
stratificata, dove ogni categoria di componenti utilizza le interfacce fornite
dal livello superiore per assolvere la propria funzione.

------------------------
 Sendable
 NetworkNode
 ReThunderNode
 SlaveNode
 SpecializedSlaveNode
------------------------

Table: Gerarchia delle interfacce utilizzate per arrivare fino
all'implementazione finale dei nodi Slave.


### Network

La rete nel suo complesso è descritta da un oggetto di tipo `Network`.
Questo contiene vari parametri utili a inizializzare i nodi (come il ritardo di
trasmissione), e a fornire loro un contesto di funzionamento.
Tra le cose più importanti, `Network` contiene il grafo di rete.
Questo viene creato automaticamente, ma è anche possibile specificare un
grafo nel costruttore, in modo da poter scegliere quale tipo di grafo
utilizzare nella rete (diretto o indiretto), e permettere quindi di modellare
situazioni in cui degli elementi sono in grado di comunicare con gli altri in
una sola direzione.

Le unità di misura temporali sono relative. Le entità nella rete richiedono di
conoscere la propria velocità di trasmissione per poter calcolare il ritardo di
trasmissione dei messaggi, ma questa non è legata a una specifica unità di
misura. La velocità di trasmissione rappresenta in quante unità tempo viene
trasmesso un messaggio di dimensione unitaria.

Le entità che vogliono gestire una trasmissione calcolano il ritardo
utilizzando la velocità configurata in `Network`, e la dimensione del
messaggio, che non viene ricavata direttamente dal messaggio ma che deve essere
specificata dall'utente assieme a questo. Questo permette all'utente di poter
scegliere l'unità di misura a cui si riferisce la velocità di trasmissione.
Nell'implementazione del protocollo, abbiamo utilizzato un frame come unità
(quindi 2 byte).


```python
class Network:

    _logging_formatter = logging.Formatter(
        fmt="[{env.now:0>3}] {levelname} in {module}: {message}", style="{"
    )

    def __init__(self, env: simpy.Environment=None, netgraph: nx.Graph=None,
                 transmission_speed=5):

        self.env = env or simpy.Environment()
        self.netgraph = netgraph or nx.Graph()
        self.transmission_speed = transmission_speed

    def run_nodes_processes(self):
        for node in self.netgraph.nodes_iter():
            if hasattr(node, 'run_proc'):
                node.run_proc()

    def configure_log_handler(self, handler):

        handler.setFormatter(self._logging_formatter)

        env = self.env

        def env_filter(record):
            record.env = env
            return True

        handler.addFilter(env_filter)

    def configure_root_logger(self, **kwargs):

        logging.basicConfig(**kwargs)

        for handler in logging.getLogger().handlers:
            self.configure_log_handler(handler)
```

`Network` contiene anche metodi utili alla configurazione dei log handler. Per
ottenere una configurazione di base, dove l'output viene diretto verso
`STDOUT`, si può chiamare la funzione `configure_root_logger` prima di
configurare altri handler. I parametri passati a questo vengono direttamente
riutilizzati in `logging.basicConfig`.

### Sendable

Il primo livello richiede la sola presenza del metodo `send_process(message:
TransmittedMessage)`. Le componenti, in questo livello del simulatore, si
occupano di:

* gestire le tempistiche di trasmissione e propagazione dei messaggi
* gestire eventuali collisioni.

Non c'è una classe da cui ereditare, viene usato solo il duck typing per
determinare l'appartenenza a questa categoria.
Ci sono due componenti che implementano direttamente `send_process`:
`NetworkNode` e `Bus`. I messaggi che vengono scambiati devono essere di tipo
`TransmittedMessage`.

#### TransmittedMessage

`TransmittedMessage` è una `namedtuple`. Questa è una classe fatta interamente
di valori immutabili, inizializzati tutti alla creazione dell'oggetto.

```python
TransmittedMessage = namedtuple('TransmittedMessage',
                                'value, transmission_delay, sender')

message = TransmittedMessage("pippo", 10, SomeSender)
```

Gli attributi di un oggetto `TransmittedMessage` sono:

* `value`, il contenuto del messaggio inviato o `CollisionSentinel` in caso
  questo non sia leggibile a causa di una collisione
* `transmission_delay`, il ritardo di trasmissione impiegato dal messaggio.
  Viene utilizzato dai nodi per capire quanto è necessario attendere prima di
  avere accesso a tutto il contenuto. 
* `sender`, l'oggetto da cui l'entità ha ricevuto il messaggio o `None` in caso
  di condizioni particolari come una collisione.

#### Bus

Nel simulatore, un bus è un oggetto utile a gestire ritardi di propagazione tra
entità nella rete. Quando un bus riceve un messaggio, il suo processo d'invio
(`send_process`) lo trattiene per un intervallo di tempo pari al ritardo di
propagazione, per poi inviarlo alle entità con cui ha connessioni.
Qualora un altro messaggio arrivasse nel bus mentre questo ne sta già gestendo
uno, il bus continua ad attendere l'intervallo prefissato, ma invece di
trattenere il messaggio produce un nuovo messaggio che rappresenta una
collisione, utilizzando i ritardi di trasmissione dei messaggi in collisione.

Un bus è utile nel modellare reti utilizzando il Channel
Model: grazie alla gestione centralizzata delle connessioni, si può infatti
stabilire sia un alfabeto di entrata che di uscita utilizzando un grafo diretto
(`nx.DiGraph`) come grafo centrale di rete. Questo vale anche per tutte le
altre entità della rete.

```python
class Bus:
    def __init__(self, network, propagation_delay):
        """
        Inizializza un Bus.

        :param network: La rete in cui si vuole inserire il bus.
        :param propagation_delay: Il ritardo di propagazione, espresso in
        tempo di simulazione.
        """

        self.env = network.env
        self._netgraph = netgraph = weakref.proxy(network.netgraph)
        self._propagation_delay = propagation_delay
        self._current_send_proc = None
        self._message_in_transmission: Optional[TransmittedMessage] = None

        netgraph.add_node(self)
```


Da `network`, il bus ottiene le informazioni più importanti necessarie alla sua
inizializzazione, tra cui l'ambiente della simulazione e il grafo di rete.
Il grafo di rete non viene assegnato direttamente, ma viene passato prima alla
funzione `weakref.proxy`, che crea un oggetto utilizzabile allo stesso modo ma
che non viene considerato nel conto dei riferimenti all'oggetto da parte di
Python. Anche `NetworkNode` adotta questo approccio, in questo modo non ci sono
riferimenti circolari tra il grafo e l'entità di rete.

Gli altri attributi vengono utilizzati per la gestione delle collisioni, come
verrà spiegato in seguito. 

##### Ricezione e invio di messaggi

Il processo che viene eseguito all'invio di un messaggio al bus è il seguente:

```python
    @simpy_process
    def send_process(self, message):

        env = self.env

        if self._current_send_proc is not None:
            self._current_send_proc.interrupt()

        self._current_send_proc = env.active_process

        if self._message_in_transmission is None:
            self._message_in_transmission = message
        else:
            logger.warning(f"{self}: A collision has happened between "
                           f"{message} and {self._message_in_transmission}")

            self._message_in_transmission = TransmittedMessage(
                CollisionSentinel,
                max(message.transmission_delay,
                    self._message_in_transmission.transmission_delay),
                None
            )

        try:
            yield env.timeout(self._propagation_delay)
        except simpy.Interrupt:
            return

        message = self._message_in_transmission
        self._message_in_transmission = None

        self._current_send_proc = None

        for node in self._netgraph.neighbors(self):
            if node is not message.sender:
                node.send_process(message)
```

Le prime e ultime azioni di questo processo riguardano l'impostare lo stato
interno del bus con informazioni attinenti all'invio. In particolare,
all'inizio si assegnano gli attributi `_current_send_proc` e
`_message_in_transmission`, che sono rispettivamente il processo d'invio stesso
e il messaggio che questo sta trasmettendo. Al termine del processo, salvo
interruzioni, a questi attributi viene assegnato `None`.

La gestione delle collisioni si basa proprio sull'interruzione del processo
d'invio. Ogni volta che viene eseguito un nuovo processo d'invio, la prima
azione che viene intrapresa è verificare l'esistenza di un altro processo
d'invio correntemente in esecuzione, controllando se questo sia assegnato a
`_current_send_proc`. Se questo c'è, il nuovo processo d'invio interrompe il
vecchio, per poi assegnare a `_current_send_proc` se stesso (ovvero il processo
in esecuzione).
Dal momento che il vecchio processo non è giunto alla sua fase conclusiva, 
dove resetta `_message_in_transmission` al valore `None`, questo avrà ancora il
valore assegnato dal precedente processo invece di `None`. Questo fatto viene
utilizzato dal processo d'invio in esecuzione per capire che c'è stata una
collisione, e che questa deve essere simulata.

Quando nel bus si verifica una collisione, il messaggio in viaggio viene
sostituito nel seguente modo:

```python
  self._message_in_transmission = TransmittedMessage(
      value=CollisionSentinel,
      transmission_delay=max(
          message.transmission_delay,
          self._message_in_transmission.transmission_delay
      ),
      sender=None
  )
```

`CollisionSentinel` è in gergo un oggetto sentinella, ovvero un oggetto
singleton che, assegnato a una variabile, indica una particolare condizione.
In questo caso, la condizione che viene segnalata è che il messaggio ricevuto è
stato oggetto di una collisione e che non è leggibile. Per verificare se un
messaggio sia stato soggetto di collisioni, un'entità può usare la seguente
formula:

```python
if received is CollisionSentinel:
    pass  # è avvenuta una collisione e il messaggio è illeggibile
```

### NetworkNode

Un NetworkNode è l'entità più importante della simulazione. In modo simile al
bus, gestisce le collisioni e il trasporto dei messaggi. La differenza
principale è che fornisce anche interfacce per l'invio e la ricezione di
messaggi disponibili per l'uso da parte delle sottoclassi.

A livello di trasporto un `NetworkNode` gestisce i ritardi di trasmissione e
l'occupazione della rete. In particolar modo, le funzioni offerte da
`NetworkNode` alle sottoclassi non permettono la trasmissione da parte del nodo
se la rete non è libera. Il meccanismo che gestisce l'attesa dei ritardi è
simile a quello utilizzato nei bus, ma viene utilizzato per tenere conto del
ritardo di trasmissione invece che di propagazione.

#### Funzioni per le sottoclassi

Le funzioni fornite da `NetworkNode` sono:

* `_transmit_process(self, message_val: Any, message_length: int)`  
  Trasmette un messaggio alle entità connesse al nodo.

* `_receive_ev(self)`  
  Restituisce un evento che scatta alla prossima ricezione di un messaggio da
  parte del nodo. Il valore dell'evento sarà il messaggio ricevuto.

`send_process` e `_transmit_process` vengono implementate tramite l'uso di un
metodo, `__occupy(message: TransmittedMessage, in_transmission: bool)`. Questo
è un generatore che si occupa di gestire lo stato della rete dal punto di vista
del nodo, comportandosi in maniera diversa a seconda se il nodo sia in
ricezione o in trasmissione. Sia `send_process` che `_transmit_process`
chiamano `__occupy` al loro interno, utilizzando la sintassi `yield from`, la
quale trasferisce il controllo da un generatore a un altro. Questo permette di
avere un controllo unificato del meccanismo di funzionamento, invece che avere
due parti separate da sincronizzare.

#### Occupazione della rete

Il metodo `__occupy` inizia così:

```python
    def __occupy(self, message: TransmittedMessage, in_transmission):

        env = self.env
        this_proc = env.active_process

        if in_transmission:
            while self._current_occupy_proc is not None:
                yield self._current_occupy_proc
        else:
            if self._current_occupy_proc is not None:
                self._current_occupy_proc.interrupt()
```

`in_transmission` deve essere di tipo `bool`, se `True` sta a significare che
l'occupazione della rete richiesta è dovuta a un atto di trasmissione. In
questo caso, invece di forzare l'interruzione dell'operazione corrente, il nodo
attende che non ci siano operazioni in corso prima di iniziare, in modo da non
creare collisioni.
È anche da notare anche che l'operazione corrente di rete può giungere al
termine e nel mentre ne potrebbe iniziare un'altra. Per questa ragione, il
processo al termine dell'attesa riprende ad attendere un eventuale processo
successivo in esecuzione, e smette di attendere solo quando
`self._current_occupy_proc` è `None`.

Se invece `in_transmission` è `False` e l'occupazione della rete è dovuta alla
ricezione di qualcosa, il processo precedente viene interrotto.

Nel passaggio successivo `__occupy` registra il tempo di inizio della fase di
occupazione della rete, utile al calcolo del ritardo di trasmissione di un
messaggio colluso.

```python
        last_transmission_start = self._last_transmission_start
        self._last_transmission_start = env.now
```

Si controlla poi l'avvenuta collisione allo stesso modo in cui si è controllata
all'interno di `Bus`, ovvero verificando se un processo non è arrivato a
conclusione, permettendo l'assegnazione di `None` a
`self._message_in_transmission`. Se non vi sono collisioni, il processo prende
il messaggio con cui si richiede l'occupazione e attende il ritardo di
trasmissione di questo. Altrimenti si intraprende la procedura di simulazione
della collisione, il contenuto del messsaggio è sostituito da
`CollisionSentinel` e si ricalcola un nuovo ritardo di trasmissione, assieme al
tempo di attesa restante. 

Il tempo di attesa rimanente viene calcolato prendendo il massimo tra:

* quanto sarebbe rimasto da attendere per la trasmissione del messaggio
  precedente
* il ritardo di trasmissione del messaggio in arrivo.

Per calcolare il nuovo ritardo di trasmissione, invece, si prende quanto è
stato atteso e vi si aggiunge il nuovo tempo di attesa.

```python

        if self._message_in_transmission is None:
            self._message_in_transmission = message
            to_wait = message.transmission_delay
        else:
            logger.warning(f"{self}: A collision has happened between "
                           f"{message} and {self._message_in_transmission}")

            last_occupation_time = env.now - last_transmission_start

            remaining_occupation_time = (
                self._message_in_transmission.transmission_delay -
                last_occupation_time
            )

            to_wait = max(message.transmission_delay,
                          remaining_occupation_time)

            self._message_in_transmission = TransmittedMessage(
                CollisionSentinel,
                last_occupation_time + to_wait,
                None
            )
```

Se si è in trasmissione, si invia il messaggio così elaborato ai propri vicini
nel grafo di rete, per poi intraprendere l'attesa vera e propria della
segnalazione di occupazione del bus.

```python
        if in_transmission:
            for n in self._netgraph.neighbors(self):
                n.send_process(message)

        try:
            yield env.timeout(to_wait)
        except simpy.Interrupt:
            return
```

Al termine, si eseguono le operazioni di pulizia, e se il messaggio è stato
ricevuto dal nodo, l'evento della ricezione da parte del nodo viene segnalato.

```python
        message = self._message_in_transmission
        self._message_in_transmission = None

        self._current_occupy_proc = None

        if not in_transmission:
            self._receive_current_transmission_cond.broadcast(message.value)
```

`_receive_ev` utilizza la segnazione, e viene implementato in questo modo:

```python
    def _receive_ev(self):
        return self._receive_current_transmission_cond.wait()
```

### Esempio di simulazione

Qua viene mostrato uno unit test utilizzato nel corso dello sviluppo riadattato
per mostrare il funzionamento delle interfacce dell'infrastruttura di rete.

I meccanismi di funzionamento delle entità vengono contenuti, per convenzione,
nella funzione `run_proc`, che restituisce un processo. In `Network` c'è un
metodo, `run_node_processes`, che esegue la funzione `run_proc` per tutti i
nodi nel grafo che l'hanno come attributo, quindi eseguendo e avviando i
processi di tutti i nodi. La convenzione dell'uso di `run_proc` viene mantenuta
nell'implementazione del protocollo.

I nodi che usano l'infrastruttura sono i seguenti, e sono molto semplici in
funzionalità:

* `ReceiverNode` è sempre in ascolto, e quando riceve un messaggio lo salva
  insieme al suo tempo di arrivo:

```python
class ReceiverNode(NetworkNode):

    def __init__(self, network):

        super().__init__(network)

        self.received: List[Tuple[int, Any]] = []
        self.run_until = lambda: False

    @simpy_process
    def run_proc(self):

        while not self.run_until():

            message = yield self._receive_ev()
            self.received.append((self.env.now, message))
```

* `SenderNode` invia i messaggi che ha salvati in una coda fino al loro
  esaurimento:

```python
class SenderNode(NetworkNode):

    def __init__(self, network, send_queue: Iterable[Any]=()):

        super().__init__(network)
        self.__send_queue = collections.deque(iterable=send_queue)

    @simpy_process
    def run_proc(self):

        send_queue = self.__send_queue

        while len(send_queue) > 0:
            msg_to_send = send_queue.popleft()
            yield self._transmit_process(*msg_to_send)

```

A partire da queste entità si configura una rete composta da un `SenderNode`,
un `ReceiverNode` e un `Bus` che li unisce. Il sender invierà dieci messaggi al
receiver, tutti di lunghezza 8.


```python
network = Network(transmission_speed=2)
messages = [(f'Message{i}', 8) for i in range(10)]

sender = SenderNode(network, messages)
receiver = ReceiverNode(network)
bus = Bus(network, 4)

network.netgraph.add_star((bus, sender, receiver))
network.run_nodes_processes()
network.env.run()
```

Alla fine della simulazione, `receiver.recieved` contiente tutti i messaggi
inviati da `sender` con il loro tempo di arrivo.

```python
print(receiver.received)

# Output: [(8, 'Message0'), (12, 'Message1'), (16, 'Message2'), ...]
```

\pagebreak

## Implementazione del Protocollo

A partire da `ReThunderNode`, l'implementazione riguarda il protocollo invece
dell'infrastruttura. `ReThunderNode` implementa le operazioni di base comuni 
al master e agli slave, tra cui l'aggiornamento delle tabelle di rumore e di
routing e la segnalazione dell'arrivo di pacchetti. A questo punto, i messaggi
scambiati dalle entità sono di tipo `Packet`, che rappresenta un pacchetto
all'interno del protocollo.

### Pacchetti

Per gestire la varietà di strutture possibili per i pacchetti del protocollo, 
è stata usata l'ereditarietà multipla, creando dei blocchi di base componibili
con cui mettere inseme la struttura finale e completa di un pacchetto.

Ogni sottotipo di pacchetto ha una serie di attributi, rappresentanti i campi
del pacchetto. Per permettere di avere una dichiarazione univoca di ognuno
degli attributi, ci sono dei sottotipi di pacchetto intermedi, dichiarati come
astratti, che hanno come scopo quello di mettere a disposizione attributi ai
sottotipi sottostanti. Questo è utile perché a ogni tipo di pacchetto non è
accompagnata solo la dichiarazione degli attributi, ma anche il metodo di
calcolo della loro dimensione in frame, come verrà mostrato in seguito.

Tutti i pacchetti ereditano dalla classe `Packet`. Questa mette a disposizione
i metodi utili alla simulazione degli errori nei frame, e al conto dei frame
contenuti in un pacchetto.

#### Lunghezza dei campi

Per evitare errori dovuti all'uso di dati troppo grandi per poter entrare nei
campi, abbiamo creato un descrittore, ovvero una classe che definisce il
comportamento in caso di accesso o assegnazione di un attributo. Il
descrittore, chiamato `FixedSizeInt`, verifica che il numero assegnato non
superi in numero di bit una quantità stabilita alla sua creazione.

```python
class FixedSizeInt:

    def __init__(self, max_bits):
        self._data = defaultdict(int)
        self.max_bits = max_bits

    def __get__(self, instance, owner):
        return self._data[instance]

    def __set__(self, instance, value):

        if not isinstance(value, int):
            raise TypeError("Value must be int")

        if value.bit_length() > self.max_bits:
            raise ValueError("Integer too big for this field")

        self._data[instance] = value
```

L'attributo `_data` contiene i vari valori dell'attributo per ognuna delle
istanze. `__get__` definisce il comportamento in caso di accesso all'attributo,
che in questo caso è di restituire il valore appartenente all'istanza.
`__set__` stabilisce invece il comportamento in fase di assegnazione. Durante
questa, prima di salvare il valore, si controlla se questo sia un intero e se
questo superi la dimensione stabilita all'inizio. In caso una delle verifiche
non vada a buon fine, viene lanciata un'eccezione.

#### Simulazione degli errori

La simulazione degli errori, e quindi del rumore nella rete, si basa sul
salvare quanti errori ha ciascun frame. La struttura utilizzata per questo è il
`defaultdict`, che si comporta in maniera analoga a un `dict` (un'HashMap), ma
che assegna automaticamente un valore di default (in questo caso 0) quando
viene richiesta una chiave non contenuta al suo interno. In questo modo,
vengono memorizzati solo gli indici dei frame in errore.

Per simulare un errore, si usa il metodo `damage_frame`:

```python
    def damage_frame(self, frame_index=None, errors=1):

        if frame_index is None:
            frame_index = random.randrange(self.number_of_frames())

        if not 0 <= frame_index < self.number_of_frames():
            raise IndexError('Frame index out of range')

        self.__frame_errors[frame_index] += errors
```

Se non viene specificato l'indice di un frame, ne viene scelto uno a caso. Il
metodo controlla se l'indice del frame è valido prima di segnare l'errore (o
gli errori).

Si può ottenere una view dei frame danneggiati tramite il metodo
`damaged_frames`, ma più spesso è utile usare i metodi presenti in `Packet` per
ottenere l'informazione che si sta cercando.

```python
    def damaged_frames(self):
        return self.__frame_errors.items()

    def frame_error_average(self):

        frame_errors = sum(max(error_count, 2)
                           for error_count in self.__frame_errors.values())

        return frame_errors / self.number_of_frames()

    def is_readable(self):
        return all(errors < 2 for errors in self.__frame_errors.values())

    def remove_errors(self):
        self.__frame_errors = defaultdict(int)
```

I metodi tengono in conto della codifica dei frame, e considerano che il
massimo numero di errori rilevabili tramite questa è 2. Per questo motivo,
`frame_error_average` fa la media, per tutti i frame danneggiati, con un valore
che può essere al massimo 2. Vi è poi il metodo `remove_errors`, utile quando
si vuole rinviare un pacchetto precedentemente danneggiato.

Un pacchetto viene considerato leggibile quando tutti i frame sono leggibili,
quindi quando non ci sono frame con più di un errore. Gli altri pacchetti
vengono scartati.

#### Conto dei frame

Ogni pacchetto ha un numero di frame dipendente dal suo contenuto. Ne consegue
che il conto dei frame nel pacchetto varia in base al tipo di pacchetto, e che
ogni tipo di pacchetto deve quindi dichiarare quanti frame contiene.

Per questa ragione, a ogni sottoclasse di `Packet` è richiesto di implementare
il metodo `_frame_increment`. Questo deve restituire il numero di frame che il
sottotipo di pacchetto contribuisce ad aggiungere con i suoi attributi.

Per ottenere il conto totale dei frame, si usa il seguente metodo di `Packet`,
`number_of_frames`:

```python
    def number_of_frames(self):
        return sum(
            cls._frame_increment(self)
            for cls in inspect.getmro(type(self)) if issubclass(cls, Packet)
        )
```

Il metodo utilizza la funzione `inspect.getmro`. In questo nome, MRO sta per
Method Resolution Order ed è l'elenco ordinato delle classi in cui Python
controlla la presenza di un metodo nel momento della chiamata di questo.
Ne consegue che la lista contiene tutte le classi da cui il pacchetto ha
ereditato. Si può notare anche che le classi sono oggetti di prima classe in
Python.

Le classi vengono utilizzate per chiamare, per ognuna di queste, la propria
versione di `_frame_increment`. Viene restituita poi la somma di tutti i valori
ottenuti.

Dalla modalità di aggiunta dei campi al pacchetto, consegue che è possibile
verificare la presenza di un campo in un pacchetto sia nel modo idiomatico in
Python, tentando l'accesso all'attributo e utilizzando blocchi `try` e `catch`
per riprendersi dall'eventuale `AttributeError`, oppure verificando se
l'attributo sia istanza della classe contente la definizione del o degli
attributi.

```python
if isinstance(packet, PacketWithSource):
    source = packet.source_static
```

Viene preferito quest'approccio per capire quale tipo di pacchetto è stato
ricevuto, invece di controllare il valore dei suoi campi interni. Questo
permette di evitare errori di sincronizzazione, dove i campi del pacchetto (in
particolare `code`) segnalano, per eventuali errori di programmazione, un tipo
diverso rispetto a quello che la sua struttura rappresenta.

Da qui si procede a descrivere i principali sottotipi e tipi di pacchetto.

#### Sottoclassi di `Packet`

I seguenti tipi di pacchetto aggiungono attributi riguardanti gli indirizzi nei
campi fissi:

* `PacketWithPhysicalAddress`, che contiene il campo `physical_address`
* `PacketWithSource`, che contiene i campi `source_static` e `source_logic`
* `PacketWithNextHop`, che contiene il campo `next_hop`

In `PacketWithSource` e `PacketWithNextHop` la semantica degli attributi resta
più o meno invariata nei vari tipi di pacchetto, mentre `physical_address`,
usato nei pacchetti di Hello, a seconda del contesto è l'indirizzo del
mittente o del destinatario. Oltre alle strutture, l'operazione di Hello non è
stata implementata.

`PacketWithSource` e `PacketWithNextHop` vengono utilizzati per implementare la
sottoclasse da cui ereditano direttamente `RequestPacket` e `ResponsePacket`,
ovvero `CommunicationPacket`:

```python
class CommunicationPacket(PacketWithSource, PacketWithNextHop):

    payload_length  = FixedSizeInt(FRAME_SIZE)

    def __init__(self):
        super().__init__()
        self.payload = None
        self.payload_length = 0

    @abc.abstractmethod
    def _frame_increment(self):
        
        if self.payload is None:
            return 0
        else:
            quot, remainder = divmod(self.payload_length, 4)
            return quot * 3 + remainder + 1

```

La classe aggiunge payload e lunghezza del payload, campo che viene contato nel
conto dei frame solo se il payload è diverso da `None`. Nel protocollo reale la
presenza del payload è segnalata dal campo `code`, e in caso di assenza di
questo, non è presente neanche il campo `payload_length`.

La quantità dei frame aggiunti dal payload viene calcolata considerando la
codifica del payload secondo il protocollo, che codifica 4 byte in 3 frame e
quelli avanzati in tanti frame quanti ne sono. Infine viene aggiunto il frame
del campo `payload_length`.

#### `RequestPacket`

`RequestPacket` è il pacchetto di richiesta inviato dal master a uno slave. La
classe che lo definisce è la seguente:

```python

class RequestPacket(CommunicationPacket):

    __STATIC_FRAMES = 1

    destination = FixedSizeInt(FRAME_SIZE)

    def __init__(self):

        super().__init__()

        self.path: List[Tuple[AddressType, int]] = None
        self.new_logic_addresses: Dict[int, int] = None

    def __repr__(self):
        return f'<RequestPacket tok={self.token} source={self.source_static} ' \
               f'next_hop={self.next_hop}>'

    def _frame_increment(self):

        frames = self.__STATIC_FRAMES
        
        path_len = len(self.path or ())

        if path_len > 0:
            frames += path_len + bitmap_frame_count(path_len) + 1

        new_addrs_len = len(self.new_logic_addresses or ())

        if new_addrs_len > 0:
            frames += new_addrs_len * 2 + 1

        return frames

```

`RequestPacket` aggiunge il campo `destination`, che rappresenta la tappa
intermedia successiva a cui il messaggio deve arrivare, la lista `path` e il
dizionario `new_logic_addresses`. Gli indirizzi del path sono salvati come
tuple, dove il primo campo contiene il tipo di indirizzo (statico o logico),
mentre il secondo l'indirizzo vero e proprio. I tipi di indirizzo sono
rappresentati da questa enumerazione:

```python
class AddressType(enum.Enum):
    logic = 0
    static = 1
```

Nel protocollo reale, il tipo di indirizzo viene segnalato da una bitmap, dove
è presente un bit per indirizzo che segnala se questo è statico o logico. È
necessario quindi tenere in conto della dimensione della bitmap nel calcolo
della dimensione del pacchetto. La funzione che calcola la dimensione della
bitmap è la seguente.

```python
def bitmap_frame_count(list_len: int):
    return math.ceil(list_len / FRAME_SIZE)
```

Allo stesso modo del payload, la presenza del path viene segnalata dal campo
`code`, e con questa la presenza del campo contente la sua lunghezza. Se il
path è presente con lunghezza maggiore di 0, viene contato un frame in più per
questa ragione.

Lo stesso ragionamento viene seguito con la tabella dei nuovi indirizzi, e
viene aggiunto un frame al conto se questa ha una lunghezza maggiore di 0.
Visto che la tabella è salvata in un `dict`, chiamare `len` su questo
restituisce solo il numero di chiavi. Per contare anche i valori, è necessario
raddoppiare il numero.

#### `ResponsePacket`

`ResponsePacket` rappresenta i pacchetti inviati come risposta dagli slave ai
master. Questi pacchetti aggiungono alla catena dei pacchetti le tabelle di
rumore, e sono descritti dalla seguente classe:

```python

class ResponsePacket(CommunicationPacket):

    def __init__(self):
        super().__init__()
        self.noise_tables: List[Dict[int, int]] = []

    def __repr__(self):
        return f'<ResponsePacket tok={self.token} ' \
               f'source={self.source_static}  next_hop={self.next_hop}>'

    def _frame_increment(self):

        frames = len(self.noise_tables)
        frames += sum(len(table) * 2 for table in self.noise_tables)

        return frames
```

Le tabelle di rumore sono una di seguito all'altra, con un campo lunghezza che
precede ciascuna di queste. Per questo motivo viene aggiunto un frame per
ognuna di queste e sommato alla dimensione delle tabelle stesse.

### ReThunderNode

`ReThunderNode` contiene i meccanismi di funzionamento comuni a `MasterNode` e
`SlaveNode`, in particolare i meccanismi di ricezione dei pacchetti e di
aggiornamento delle tabelle di rumore e di routing.

`ReThunderNode` viene inizializzato con `Network`, come le altre entità della
rete, poi con un indirizzo statico e facoltativamente con uno logico. Al suo
interno, `ReThunderNode` inizializza anche la tabella di rumore e la tabella di
routing:

```python

class ReThunderNode(NetworkNode):

    def __init__(self, network, static_address: int,
                 logic_address: Optional[int]):

        super().__init__(network)
        self.static_address = static_address
        self.logic_address = logic_address
        self.noise_table = {}
        self.routing_table = {}
        self._receive_packet_cond = BroadcastConditionVar(self.env)

        self._receive_current_transmission_cond.callbacks.append(
            self._check_packet_callback
        )
```

`_receive_packet_cond` è una condizione che viene fatta scattare quando un
oggetto ricevuto dal nodo è un pacchetto valido e leggibile. Viene utilizzata
per implementare `_received_packet_ev`, che viene usata da `MasterNode` e
`SlaveNode` per attendere di aver ricevuto un pacchetto valido:

```python

    def _receive_packet_ev(self):
        return self._receive_packet_cond.wait()

```

Per far scattare `_receive_current_transmission_cond` viene utilizzata la
propagazione delle callback di `BroadcastConditionVar`. Alle callback di
`_receive_current_transmission_cond`, che come descritto prima è la condizione
che viene fatta scattare all'arrivo di una trasmissione, viene aggiunta
`_check_packet_callback`. Questa funzione è un metodo che esegue le seguenti
operazioni:

1. Controlla la validità del pacchetto in base a questi criteri:
    * il pacchetto deve non essere stato oggetto di collisione
    * il pacchetto deve essere istanza di `Packet`
    * il pacchetto non deve avere frame danneggiati al punto di non essere
      recuperabili con Hamming.

2. Se il pacchetto è valido aggiorna le tabelle di rumore e di routing con i
   dati prelevati dal pacchetto

3. Chiama `_receive_current_packet_cond.signal(<pacchetto ricevuto>)`.

In questo modo, l'aggiornamento delle tabelle è trasparente nei confronti di
`MasterNode` e `SlaveNode`, che possono aspettarsi di avere i valori delle
tabelle aggiornati prima della ricezione del pacchetto.

### Gestione degli indirizzi: NodeDataManager

Prima di discutere di MasterNode, si discuterà della gestione degli indirizzi
da parte del master. La gestione degli indirizzi ha richiesto un attenzione
particolare per via di alcuni requisiti importanti per un'implementazione
efficiente degli algoritmi utili al routing nel protocollo. In particolare si
vuole:

* ottenere le informazioni di un nodo avente un determinato indirizzo statico
  in $O(1)$
* ottenere le informazioni di un nodo avente un determinato indirizzo logico in
  $O(1)$
* poter ottenere indirizzi statici e dinamici disponibili in modo efficiente
* avere accesso facile alle informazioni sugli indirizzi di un nodo, e essere
  sicuri che queste siano aggiornate
* controllare che la gestione degli indirizzi sia corretta (es. non ci devono
  essere nodi con lo stesso indirizzo logico).

Per venire in contro a questi requisiti, abbiamo creato un gestore delle
informazioni dei nodi, NodeDataManager. 

#### Funzionamento

NodeDataManager struttura le informazioni che ha su di un nodo con la classe
NodeData:

```python

    class NodeData:

        def __init__(self, node_manager, static_address=None,
                     logic_address=None):

            node_manager = weakref.proxy(node_manager)

            self._node_manager = node_manager
            self._static_address = (
                static_address or node_manager.get_free_static_address()
            )
            self._logic_address = None
            self.logic_address = logic_address
            self.current_logic_address = None

            node_manager._on_create(self)

```

Quando a NodeDataManager vengono chieste informazioni su di un nodo, viene
restituito un oggetto di questo tipo. Gli oggetti di tipo NodeData vengono
utilizzati da MasterNode come nodi del grafo che rappresenta la situazione
interna della rete.

Ogni volta che un oggetto NodeData viene creato, questo chiama `_on_create` sul
gestore dei nodi a cui appartiene con se stesso come argomento.
Questa operazione ha lo scopo di:

* verificare se esiste già un nodo che ha lo stesso indirizzo statico, e in
  quel caso segnalare un errore
* aggiornare il riferimento di NodeDataManager al nodo.

L'aggiornamento al riferimento è dovuto al fatto che NodeDataManager salva i
riferimenti ai nodi in un `SortedDict`, dove gli indici sono indirizzi statici.

NodeDataManager salva in un altro `SortedDict` gli stessi riferimenti, dove le
chiavi sono però indirizzi logici. In questo modo è possibile accedere in tempo
costante a un nodo sia tramite l'indirizzo statico, che tramite l'indirizzo
logico.

La ragione per cui abbiamo scelto di usare `SortedDict` come struttura dati è
di non aver bisogno di un'ulteriore struttura per gestire gli indirizzi. In
questo modo, infatti, le chiavi dei dizionari salvano già tutti gli indirizzi
utilizzati ordinatamente, permettendo di poter sia controllare l'assegnazione
di un indirizzo in tempo costante, sia di poter trovare indirizzi liberi in
modo abbastanza veloce ($O(log(n))$ nel caso peggiore usando la ricerca
binaria). Pur essendo l'address space abbastanza piccolo (massimo 2048
indirizzi), abbiamo dato attenzione a questo aspetto considerando che le
operazioni descritte devono essere eseguite molto frequentemente.

Per avere la certezza della correttezza dell'assegnazione degli indirizzi,
`logic_address` è una proprietà in NodeData, definita da:

```python
    class NodeData:

        ...

        @property
        def logic_address(self):
            return self._logic_address

        @logic_address.setter
        def logic_address(self, logic_addr):
            self._node_manager._map_to_logic(self, logic_addr)
            self._logic_address = logic_addr

```

`_map_to_logic` esegue due operazioni: controlla che l'indirizzo logico che si
sta assegnando non sia già in uso da parte di un altro nodo, e aggiorna il
dizionario degli indirizzi logici in NodeDataManager associando il nodo al
nuovo indirizzo logico. Se l'indirizzo logico non può essere utilizzato, viene
lanciato un `ValueError`.

Se dovesse essere necessario resettare l'indirizzo logico di un nodo, si può
fare assegnando a questo uno dei valori in `flag_values`:

```python
    FLAG_VALUES = frozenset([None])
```

Il valore utilizzato è solamente `None`, ma abbiamo scelto questa struttura per
poter eventualmente assegnare altri valori a `logic_address`, che potessero
segnalare altre condizioni (come un aggiornamento di indirizzi fallito).
Abbiamo poi optato per una soluzione diversa per questo scenario, come verrà
mostrato in seguito.

Se fosse necessario assegnare a un nodo l'indirizzo logico di un altro nodo, si
può fare in uno di questi modi:

* assegnando `None` a `logic_address` del nodo a cui si vuole copiare
  l'indirizzo

* chiamando `swap_logic_address(self, node)` su di uno dei due nodi. Questo
  metodo scambia gli indirizzi logici di due nodi.

L'effetto di assegnare `None` all'indirizzo logico di un nodo è quello di
eliminare la mappatura da parte di NodeDataManager dall'indirizzo logico al
nodo. Dopo questa operazione, l'indirizzo logico è assegnabile.

```python

class NodeDataManager:

    ...

    def _map_to_logic(self, node: NodeData, new_logic_address):

        logic_to_node = self._logic_to_node

        invalid_previous_addr = node.logic_address in self.FLAG_VALUES
        only_delete = new_logic_address in self.FLAG_VALUES
        already_assigned = (
            logic_to_node.get(new_logic_address, self) is not self
        )

        if already_assigned:
            raise ValueError('The logic address is already assigned.')
        if not invalid_previous_addr:
            del logic_to_node[node.logic_address]
        if not only_delete:
            logic_to_node[new_logic_address] = node

```

NodeData contiene due indirizzi logici: `logic_address`, di cui si è discusso,
e `current_logic_address`. La differenza tra i due è che `logic_address` è
l'indirizzo logico corretto da assegnare al nodo deciso dal Master, mentre
`current_logic_address` è l'indirizzo logico che il master è sicuro essere
assegnato al nodo. `current_logic_address` è un normale attributo a cui non
sono associate mappature, e viene usato per capire quando un nodo ha bisogno di
ricevere un aggiornamento dell'indirizzo.

#### Interfaccia

NodeDataManager offre diverse funzioni, di cui le più importanti sono:

* `get_free_static_address(self)`, restituisce un indirizzo statico libero

* `__getitem__(self, item)`, restituisce il nodo con indirizzo statico `item`

* `from_logic_address(self, addr)`, restituisce il nodo con l'indirizzo logico
  indicato

* `logic_addresses_view(self)`, offre una view del dizionario degli indirizzi
  logici, permettendo di iterare ordinatamente su questi

`__getitem__` è uno special method in Python, che viene utilizzato per
implementare l'operatore subscript. Per ottenere un nodo con un determinato
indirizzo statico si usa l'operatore subscript su NodeDataManager con
l'indirizzo statico del nodo (ad esempio, per ottenere informazioni sul nodo
con indirizzo 3, si usa `nodemanager[3]`). Questo permette a NodeDataManager
di implementare `collections.Mapping`, il che può essere utile per alcune
funzioni che richiedono quest'interfaccia (ad esempio, alcune funzioni di
NetworkX usano questo metodo per rietichettare i nodi dei grafi).

### MasterNode

MasterNode è l'entità principale di una rete che implementa il protocollo. 



### SlaveNode

SlaveNode implementa gli strumenti necessari a gestire il routing per uno
slave, e fornisce gli strumenti per implementare un protocollo di livello
applicativo. L'esecuzione delle operazioni di routing è affidata al processo
`run_proc(self)`, che esegue ciclicamente le operazioni necessarie.

L'implementazione del protocollo di livello applicativo può essere fatta in due
modi:

* creando una sottoclasse di `SlaveNode`
* fornendo una funzione da chiamare all'arrivo di un messaggio allo slave
  nell'inizializzatore di `SlaveNode`

In entrambe le soluzioni, sostanzialmente, si richiede l'implementazione di una
funzione con la seguente forma:

```python
def on_message_received(self, payload, payload_length) -> answer, answer_len:
    ...
```

`self` è il nodo che riceve il messaggio. La funzione deve restituire un
payload da rinviare al master e la sua lunghezza. L'implementazione di default
di questa funzione presente in SlaveNode restituisce incondizionatamente
payload `None` e lunghezza 0.

Alla ricezione di un pacchetto valido, SlaveNode ne estrae il payload e la
lunghezza, e chiama la funzione `self.on_message_received`.

Il ciclo di funzionamento di `run_proc` in SlaveNode è molto semplice:

```python

    @simpy_process
    def run_proc(self):

        logger.info(f"{self} started.")

        while not self.run_until():

            received: Packet = yield self._receive_packet_ev()
            response: Packet = self._handle_received(received)

            if response is not None:
                logger.debug(f"{self} is sending {response}")
                self._transmit_process(
                    response, response.number_of_frames()
                )

```

L'attributo `run_until` di SlaveNode può essere impostato a una funzione che
restituisca `False` quando si vuole interrompere l'esecuzione del nodo. Fino a
quel momento, SlaveNode esegue le seguenti operazioni:

* attende di ricevere un pacchetto
* elabora una risposta
* se il pacchetto ricevuto genera una risposta immediata, la trasmette.


