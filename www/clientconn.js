/*
send messages via clientConn.send
receive messages by providing an onMessage function

requires my js-util project
*/

ClientConn = makeClass({
	init : function(args) {
		if (args.uri !== undefined) this.uri = args.uri;
		if (this.uri === undefined) throw "expected uri";

		var clientConn = this;
	
		//callback on received message
		this.onMessage = args.onMessage;

		//buffer responses until we have a connection
		this.sendQueue = [];
	
		//register implementation classes
		this.AsyncComm = makeClass();

		this.AsyncCommWebSocket = makeClass({
			name : 'AsyncCommWebSocket',
			super : clientConn.AsyncComm,
			init : function(done) {
				this.connected = false;
				this.reconnect(done);
			},
			reconnect : function(done) {
				if (this.connected) return;
				var thiz = this;
				this.ws = new WebSocket('ws://'+clientConn.uri);
				this.ws.onopen = function(evt) {
console.log('websocket onopen', evt);
					thiz.connected = true;
					if (done) done();
				};
				this.ws.onclose = function(evt) {
console.log('websocket onclose', evt);
					thiz.connected = false;
				};
				this.ws.onmessage = function(evt) {
//console.log('websocket onmessage', evt);
					clientConn.onMessage(evt.data);
				};
				this.ws.onerror = function(evt) {
console.log('websocket onerror', evt);
				};
			},
			send : function(data) {
				this.ws.send(data);
			}
		});


		this.AsyncCommAjax = makeClass({
			//static variable
			sessionID : undefined,
			
			name : 'AsyncCommAjax',
			super : clientConn.AsyncComm,
			init : function(done) {
				this.connected = true;
				this.sendQueue = [];
				this.partialMsg = '';
				this.poll();
				if (done) done();
			},
			reconnect : function() {},	//nothing right now
			poll : function() {
				var thiz = this;
				setTimeout(function() {
					var sendQueue = thiz.sendQueue;
					//cookies cross domain?  port change means domain change?  just wrap sessions into the protocol ...
					if (this.sessionID !== undefined) {
						sendQueue.splice(0, 0, 'sessionID '+this.sessionID);
					}
					thiz.sendQueue = [];
					$.ajax({
						type : 'POST',
						url : 'http://'+clientConn.uri,
						data : JSON.stringify(sendQueue),
						//dataType : 'json',
						success : function(msgsdata) {
							console.log('got '+msgsdata);
							var msgs = $.parseJSON(msgsdata)
							//process responses
							for (var i = 0; i < msgs.length; i++) {
								var msg = msgs[i];
								if (msg.substring(0,10) == 'sessionID ') {
									clientConn.AsyncCommAjax.prototype.sessionID = msg.substring(10);
								} else if (msg.substring(0,10) == '(partial) ') {
									var part = msg.substring(10);
									thiz.partialMsg += part;
								} else if (msg.substring(0,13) == '(partialEnd) ') {
									var part = msg.substring(13);
									var partialMsg = thiz.partialMsg + part;
									thiz.partialMsg = '';
									clientConn.onMessage(partialMsg);
								} else {
									clientConn.onMessage(msgs[i]);
								}
							}
						},
						error : function(handler, options, ex) {
							console.log("ajax error "+handler.status+' '+options+' '+ex);
						},
						complete : function() {
							thiz.poll();
						},
						timeout : 30000
					});
				}, 500);
			},
			send : function(msg) {
				this.sendQueue.push(msg);
			}
		});
	},
	
	connect : function(done) {
		this.impl = undefined;
		
		//first try websockets ...
		//mind you, the server only handles the RFC websockets
		var classes = [
			this.AsyncCommWebSocket,
			this.AsyncCommAjax
		];
		for (var i = 0; i < classes.length; i++) {
			try {
				this.impl = new classes[i](done);
				//console.log('succeeded with', classes[i].prototype.name);
				break;
			} catch (ex) {
				console.log('conn init failed '+classes[i].prototype.name+' '+ex);
			}
		}
		if (this.impl === undefined) throw 'failed to initialize any kind of async communication';
	},

	send : function(msg) {
		if (!this.impl || !this.impl.connected) {
			this.sendQueue.push(msg);
			//TODO and register a loop to check
		} else {
			if (this.sendQueue.length) {
				var thiz = this;
				$.each(this.sendQueue, function(i,msg) {
					thiz.impl.send(msg);
				});
				this.sendQueue = [];
			}
			this.impl.send(msg);
		}
	}
});

