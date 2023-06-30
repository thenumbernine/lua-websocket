/*
send messages via clientConn.send
receive messages by providing an onMessage function

requires my js-util project
*/

class ClientConn {
	constructor(args) {
		if (args.uri !== undefined) this.uri = args.uri;
		if (this.uri === undefined) throw "expected uri";

		//ok seems firefox has a problem connecting non-wss to https domains ... i guess?
		// or is that the new standard now?
		// either way since I've switched to https only (and so many others have too ...)
		// default is wss
		if (args.wsProto !== undefined) this.wsProto = args.wsProto;
		if (this.wsProto === undefined) this.wsProto = 'wss';

		if (args.ajaxProto !== undefined) this.ajaxProto = args.ajaxProto;
		if (this.ajaxProto === undefined) this.ajaxProto = 'https';

		let clientConn = this;

		//callback on received message
		this.onMessage = args.onMessage;

		//callback on closed connection
		this.onClose = args.onClose;

		//buffer responses until we have a connection
		this.sendQueue = [];

		//register implementation classes
		class AsyncComm {};
		this.AsyncComm = AsyncComm;

		class AsyncCommWebSocket extends AsyncComm {
			constructor(done) {
				super();
				this.connected = false;
				this.reconnect(done);
			}
			reconnect(done) {
				if (this.connected) return;
				let thiz = this;
				this.ws = new WebSocket(clientConn.wsProto+'://'+clientConn.uri);
				this.ws.onopen = function(evt) {
//console.log('websocket onopen', evt);
					thiz.connected = true;
					if (done) done();
				};
				this.ws.onclose = function(evt) {
console.log('websocket onclose', evt);
console.log('error code', evt.code);
					thiz.connected = false;
					if (clientConn.onClose) {
						clientConn.onClose.apply(clientConn, arguments);
					}
				};
				this.ws.onmessage = function(evt) {
//console.log('websocket onmessage', evt);
					let isblob = evt.data.constructor == Blob;
					if (isblob) {
						// blob to text, because javascript is a trash language/API
						let reader = new FileReader();
						reader.onload = function(e) {
							let text = reader.result;
							clientConn.onMessage(text);
						};
						reader.readAsText(evt.data);
					} else {
						// text ... I hope
						clientConn.onMessage(evt.data);
					}
				};
				this.ws.onerror = function(evt) {
console.log('websocket onerror', arguments);
// https://stackoverflow.com/questions/18803971/websocket-onerror-how-to-read-error-description
// optimistic but not standard .... and not showing up on chrome desktop
//console.log('error code', evt.code);
					throw evt;
				};
			}
			send(data) {
				this.ws.send(data);
			}
		}
		AsyncCommWebSocket.prototype.name = 'AsyncCommWebSocket';
		this.AsyncCommWebSocket = AsyncCommWebSocket;

		class AsyncCommAjax extends AsyncComm {
			constructor(done) {
				super();
				this.sessionID = undefined;
				this.connected = true;
				this.sendQueue = [];
				this.partialMsg = '';
				this.poll();
				if (done) done();
			}
			reconnect() {}	//nothing right now
			poll() {
				let thiz = this;
				setTimeout(function() {
					let sendQueue = thiz.sendQueue;
					//cookies cross domain?  port change means domain change?  just wrap sessions into the protocol ...
					if (thiz.sessionID !== undefined) {
						sendQueue.splice(0, 0, 'sessionID '+thiz.sessionID);
					}
					thiz.sendQueue = [];
					fetch(
						clientConn.ajaxProto+'://'+clientConn.uri,
					{
						body : JSON.stringify(sendQueue),
					}).then(response => {
						if (!response.ok) throw 'not ok';
console.log('got response',response);
						response.json(msgs => {
console.log('got msgs',msgs);
							//process responses
							for (let i = 0; i < msgs.length; i++) {
								let msg = msgs[i];
								if (msg.substring(0,10) == 'sessionID ') {
//console.log("sessionID is", msg.substring(10));
									thiz.sessionID = msg.substring(10);
								} else if (msg.substring(0,10) == '(partial) ') {
									let part = msg.substring(10);
									thiz.partialMsg += part;
								} else if (msg.substring(0,13) == '(partialEnd) ') {
									let part = msg.substring(13);
									let partialMsg = thiz.partialMsg + part;
									thiz.partialMsg = '';
									clientConn.onMessage(partialMsg);
								} else {
									clientConn.onMessage(msgs[i]);
								}
							}
							thiz.poll();
						});
					}).catch(e => {
						console.log("fetch error", e);
					});
						//timeout : 30000
						// ... does fetch have no timeout otherwise?
						// ... do I have to add 'AbortSignal.timeout(30000) to change the default?
				}, 500);
			}
			send(msg) {
				this.sendQueue.push(msg);
			}
		}
		AsyncCommAjax.prototype.name = 'AsyncCommAjax';
		this.AsyncCommAjax = AsyncCommAjax;

		//first try websockets ...
		//mind you, the server only handles the RFC websockets
		this.commClasses = [];
		if (!args.disableWebsocket) this.commClasses.push(this.AsyncCommWebSocket);
		if (!args.disableAjax) this.commClasses.push(this.AsyncCommAjax);
	}

	connect(done) {
		this.impl = undefined;
		for (let i = 0; i < this.commClasses.length; i++) {
			try {
//console.log("websocket comm attempting class", this.commClasses[i].prototype.name);
				this.impl = new this.commClasses[i](done);
console.log('websocket comm succeeded with', this.commClasses[i].prototype.name);
				break;
			} catch (ex) {
console.log('conn init failed',this.commClasses[i].prototype.name, ex);
			}
		}
		if (this.impl === undefined) throw 'failed to initialize any kind of async communication';
	}

	send(msg) {
		if (!this.impl || !this.impl.connected) {
			this.sendQueue.push(msg);
			//TODO and register a loop to check
		} else {
			if (this.sendQueue.length) {
				let thiz = this;
				this.sendQueue.forEach(msg => {
					thiz.impl.send(msg);
				});
				this.sendQueue = [];
			}
			this.impl.send(msg);
		}
	}
}

export {ClientConn};
