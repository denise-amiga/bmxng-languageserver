Rem A few things to remember
	If the user is working with a multi-root workspace;
	there may be several instances of the LSP running at the same time
	So any temporary data or similar should be stored in the workspace folder
	And NOT in any "global" location
	
	It's probably a good idea to read all available data from the client first before processing messages
	As the client will sometimes send $cancelRequest notifications
	Meaning you don't have to process the request with that ID
	
	A request message will always contain an ID
	A request message always wants a response message with the same ID
	(unless a $cancelRequest says otherwise, but a reponse to a canceled request is still okay)
	The difference between a request and reponse is that a request uses the "params" field while a reponse uses "result"
	
	If a message does not contain an ID it's called a notification
	A notification never wants a reponse and only uses "params"
	
	VS Code LSP info: https://code.visualstudio.com/api/language-extensions/language-server-extension-guide
	LSP specs: https://microsoft.github.io/language-server-protocol/specifications/specification-current/
EndRem

SuperStrict

Framework brl.standardio
Import "source/base.util.debugger.bmx"
Import "source/base.util.jsonhelper.bmx"
Import "source/lsp.core.clientcommunicator.bmx"
Import "source/lsp.core.appdata.bmx"
Import "source/lsp.methodhandler.bmx"
Import "source/lsp.methodhandler.textdocument.bmx"
Import Brl.ThreadPool
Import Brl.Textstream



'PREPARATION
'------------
Global App:TApp = TApp.GetInstance()

'ADD HANDLERS
'add all the method handlers we want to be usable
AppData.AddMethodHandler( new TLSPMethodHandler_TextDocument )
'assume unknown methods are to handle "in order" / as sequence
AppData.defaultMethodOrderHandling = 1

'DEFINE (NOT IN) ORDERED REQUESTS
'depending on the default either "in order" or "not in order" register
'will be checked to see what order-kind of method it is
 
'Some requests need to be replied in "order" (so for now we handle
'them by a single thread to ensure states are "correct")
MessageCollection.RegisterSequentialMethod("textDocument/definition")
MessageCollection.RegisterSequentialMethod("textDocument/rename")

'"not in order" methods
'app.data.messages.RegisterNonSequentialMethod("textDocument/completion")
'app.data.messages.RegisterNonSequentialMethod("textDocument/signatureHelp")
'... most probably this will be any "notification


'KICKOFF
'--------
'start lsp and wait for incoming commands
App.Run()




Type TApp
	'threads handling in/outgoing messages
	Field messageReceiverThread:TThread
	Field messageSenderThread:TThread
	'thread handling messages which are to process "in order"
	Field handleIncomingSequentialMessagesThread:TThread
	'pool for worker threads processing "less important" messages or
	'similar stuff
	Field workerThreadsPool:TThreadPoolExecutor
	
	'maximum limit of concurrent worker threads
	Global _workerThreadsLimit:Int = 4

	Global _instance:TApp

	 
	Function GetInstance:TApp()
		If Not _instance
			_instance = New TApp
			OnEnd(CleanUp)
		EndIf
		
		Return _instance
	End Function
	
	
	Method New()
		workerThreadsPool = TThreadPoolExecutor.newFixedThreadPool(_workerThreadsLimit)

		AddLog("#### BlitzMax LSP Started!~n")
	End Method
	
	
	Function CleanUp()
		AddLog("#### BlitzMax LSP Ending!~n")
	EndFunction


	Method CreateInitializeResultMessage:TLSPMessage()
		Local jsonHelper:TJSONHelper = New TJSONHelper("")
		jsonHelper.SetPathString("jsonrpc", "2.0")
		jsonHelper.SetPathInteger("id", 0)
		'server capabilities
		jsonHelper.SetPathInteger("result/capabilities/textDocumentSync", 1)
		jsonHelper.SetPathString("result/capabilities/completionProvider/triggerCharacters", ".")
		
		'server info
		jsonHelper.SetPathString("result/serverInfo/name", "BlitzMax NG Language Server")
		jsonHelper.SetPathString("result/serverInfo/version", "v0.1")
		
		Return New TLSPMessage(jsonHelper)
	End Method


	Function MessageReceiverThreadFunc:Object(data:Object)
		while not AppData.exitApp
			' Blocking - wait for anything
			local incomingContent:String = ClientCommunicator.Retrieve()

			'parse the message
			Local message:TLSPMessage = New TLSPMessage(incomingContent)


			'without "initialize":
			'- handle "initialize" 
			'- send error -32002 on each request (except "initialize")
			'- drop notifications (except "exit" notification)
			if not AppData.receivedInitializePacket
				If message.IsRequest()
					if message.IsMethod("initialize")
						AppData.receivedInitializePacket = True
						AddLog("## INITIALIZE~n")
						MessageCollection.AddOutgoingMessage( App.CreateInitializeResultMessage() )
						'wait for next message
						Continue

					Else
						MessageCollection.AddOutgoingMessage( TLSPMessage.CreateErrorMessage(message.id, TClientCommunicator.ERROR_ServerNotInitialized, "Not initialized yet") )
						'wait for next message
						Continue

					EndIf

				ElseIf message.IsNotification() 
					If message.IsMethod("exit")
						AddLog("## EXITING~n")
						AppData.exitApp = True
						'wait for next message
						Continue

					Else
						AddLog("## Skipping notifications until initialized.  method=~q" + message.methodName + "~q.~n")
						'wait for next message
						Continue

					EndIf
				EndIf

			'if initialize packet was received we hardcoded react to
			'- "initialized"
			'- "exit"
			'- "$/cancelRequest"
			Else
				If message.IsNotification() 
					If message.IsMethod("initialized")
						AddLog("## INITIALIZED~n")
						'wait for next message
						Continue

					ElseIf message.IsMethod("exit")
						AddLog("## EXITING~n")
						AppData.exitApp = True
						'wait for next message
						Continue

					ElseIf message.IsMethod("$/cancelRequest")
						local cancelledMessageID:Int = Int(message.GetPathInteger("params/id"))
						'if the "to cancel" message is still in the queues
						'then the request is replied to
						if MessageCollection.RemoveIncomingMessage( cancelledMessageID )
							'allowed to return partial results - or an error
							MessageCollection.AddOutgoingMessage( TLSPMessage.CreateErrorMessage(cancelledMessageID, TClientCommunicator.ERROR_RequestCancelled, "Request cancelled") )

							AddLog("## Request #" + cancelledMessageID + " cancelled.~n")
						Else
							AddLog("## Request #" + cancelledMessageID + " cancel skipped. Not found / already processed.~n")
						EndIf
						'wait for next message
						Continue

					EndIf
				EndIf
				
			EndIf
			

			' inform about missing method handlers
			If not AppData.HasMethodHandler(message.methodName)
				if message.IsNotification()
					AddLog("?? received unhandled notification. method=~q" + message.methodName + "~q.~n")
				Else
					AddLog("?? received unhandled request. method=~q" + message.methodName + "~q  id=" + message.id + ".~n")
				EndIf
				
				'TODO: still add (possibly this is supported later?)
				Continue
			EndIf


			MessageCollection.AddIncomingMessage(message)
		Wend
	End Function


	Function MessageSenderThreadFunc:Object(data:Object)
		While not AppData.exitApp
			While MessageCollection.GetOutgoingMessageCount() > 0
				Local message:TLSPMessage = MessageCollection.PopOutgoingMessage()
				
				ClientCommunicator.Send( message._jsonHelper.ToStringCompact() )
			Wend
			
			Delay(25)
		Wend
	End Function	


	Function HandleIncomingSequentialMessagesThreadFunc:Object(data:Object)
		While not AppData.exitApp
			'check for new unprocessed "in order" messages
			Local message:TLSPMessage = MessageCollection.PopIncomingSequentialMessage()
			If not message
				'we could try to help out with "not in order" messages
				message:TLSPMessage = MessageCollection.PopIncomingNonSequentialMessage()

				'if still no message, wait a bit until next check
				If not message
					Delay(25)
					Continue
				EndIf
			EndIf

			'stop processing if already cancelled
			if message.IsCancelled() then Continue
				
			'stop processing if handler is no longer registered
			Local handler:TLSPMethodHandler = AppData.GetMethodHandler(message.methodName)
			if not handler
				AddLog("!! received no longer handled request: method=~q" + message.methodName + "~q.~n")
				Continue
			endif

			'actually process this message
			handler.HandleMessage(message)
		Wend
	End Function
				
	
	Method Run()
		AddLog("## Starting up threads.~n")
		'kick off ingoing/outgoing message handler threads
		messageReceiverThread = CreateThread( MessageReceiverThreadFunc, null )
		messageSenderThread = CreateThread( MessageSenderThreadFunc, null )
		'start thread to handle "in order" messages 
		handleIncomingSequentialMessagesThread = CreateThread( HandleIncomingSequentialMessagesThreadFunc, null )
		
		AddLog("## Entering main loop.~n")
		While not AppData.exitApp
			'check for new incoming messages - without "in order / 
			'sequential" requirement - add them to the worker thread pool.
			'add as much as possible (and also add up to twice as much 
			'new tasks as we might finish in the threads earlier than
			'coming back to here)
			While MessageCollection.GetIncomingNonSequentialMessageCount() > 0 and workerThreadsPool.threadsWorking < workerThreadsPool.maxThreads * 2
				local message:TLSPMessage = MessageCollection.PopIncomingNonSequentialMessage()
				if not message 
					AddLog("!! invalid state: message=NULL but GetIncomingNonSequentialMessageCount() > 0.~n")
					AppData.exitApp = True
					continue
				EndIf

				'stop processing if already cancelled
				if message.IsCancelled() then Continue
				
				'stop processing if handler is no longer registered
				Local handler:TLSPMethodHandler = AppData.GetMethodHandler(message.methodName)
				if not handler
					AddLog("!! received no longer handled request: method=~q" + message.methodName + "~q.~n")
					continue
				endif

				'add to the "todo list" of the threads
				workerThreadsPool.execute( New TLSPMessageHandlerTask(handler, message) )
			Wend

			Delay(25)
		Wend

		
		AddLog("## Waiting for messageReceiverThread to shut down.~n")
		WaitThread( messageReceiverThread )
		AddLog("## Waiting for messageSenderThread to shut down.~n")
		WaitThread( messageSenderThread )
		AddLog("## Waiting for handleIncomingSequentialMessagesThread thread to shut down.~n")
		WaitThread( handleIncomingSequentialMessagesThread )
		AddLog("## Waiting for worker threads to shut down.~n")
		workerThreadsPool.shutdown()

		AddLog("## Bye.~n")
		End
	End Method
End Type




Type TLSPMessageHandlerTask extends TRunnable
	Field message:TLSPMessage
	Field handler:TLSPMethodHandler

	Method New(handler:TLSPMethodHandler, message:TLSPMessage)
		self.message = message
		self.handler = handler
	End Method


	Method run()
		if handler and message
			handler.HandleMessage(message)
		endif
	End Method
End Type

