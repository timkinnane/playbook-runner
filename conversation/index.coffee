_ = require 'underscore'
Handlebars = require 'handlebars'
HandlebarsIntl = require 'handlebars-intl'
YAML = require 'yamljs'
FS = require 'fs'
path = require 'path'
conversation = require 'hubot-dynamic-conversation'

# Add some template helpers to handlebars
HandlebarsData =
	data:
		intl:
			locales: 'en-AU'
			formats:
				time:
					report:
						day: "numeric"
						month: "long"
						year: "numeric"
						hour: "numeric"
						minute: "numeric"
Handlebars.registerHelper 'equal', (lvalue, rvalue, options) ->
	throw new Error('Tempalte helper `equal` needs 2 words') if arguments.length < 3
	if lvalue isnt rvalue
		options.inverse this
	else
		options.fn this
Handlebars.registerHelper 'toLowerCase', (input) ->
	input?.toLowerCase()
HandlebarsIntl.registerWith Handlebars

# Convert strings to regular expressions
String.prototype.toRegExp = () ->
	match = this.match new RegExp '^/(.+)/(.*)$'
	new RegExp match[1], match[2] if match

# Convert string to a hash to use as key
String.prototype.hashCode = () ->
	hash = 0
	return hash if this.length is 0
	for i in [0...@length]
		hash  = ((hash << 5) - hash) + @charCodeAt i
		hash |= 0 # Convert to 32bit integer
	return hash

# Parse text to evaluate template expressions
parseTemplate = (source, context) ->
	if context?
		template = Handlebars.compile source
		source = template context, HandlebarsData
	return source

# Conversation Engine loads and processes converations models
class ConversationEngine
	constructor: (@robot) ->
		@conversation = new conversation @robot
		@logDebug "Conversation engine initiated"
		@ignoreIncoming = false
		@models = {}
		@skipDefault = ['/\\bskip\\b$/i', '(or say [skip])']

	# adds a conversation model and key for chaining
	addModel: (key, model) ->
		return @models[key] = model

	# Read a directory of YAML files
	readDir: (filePath) =>
		@logDebug "Reading conversation models from #{ filePath }"
		try
			files = FS.readdirSync filePath
			filePaths = _.map files, (file) -> "#{ filePath }/#{ file }"
			_.each filePaths, @readFile
		catch err then @logError err

	# Read and parse YAML file, save model with filename as key
	readFile: (filename) =>
		pathParts = path.parse(filename)
		return if pathParts.ext isnt '.yml'
		try
			source = FS.readFileSync filename, 'utf8'
			@logDebug "Reading model from file #{ filename }"
			@addModel pathParts.name, YAML.parse source
		catch err then @logError err

	# Set up listeners / responders for a given model
	registerTrigger: (model, key) =>
		if model?.trigger
			triggerRegex = model.trigger.toRegExp()
			if model.private
				@logInfo "Respond to #{ model.trigger } for #{ key } model"
				@robot.respond triggerRegex, (msg) =>
					@processResponse msg, model, key
			else
				@logInfo "Listen for #{ model.trigger } for #{ key } model"
				@robot.hear triggerRegex, (msg) =>
					@processResponse msg, model, key

	# Shortcut method to register all models
	registerAll: ->
		@logInfo "Registering all #{ _.size(@models) } conversation triggers"
		_.each @models, @registerTrigger

	# Process a response - not yet within conversation
	processResponse: (msg, model, key) ->
		return @logDebug "Ignoring: #{ msg.message.text }" if @ignoreIncoming
		@logDebug "Processing: #{ msg.message.text }"
		try
			return @send msg, key, model.message if model.message # send one-liner
			@processConversation msg, model, key # or start conversation
		catch err
			@ignoreIncoming = false #start listening again if any errors
			@logError "Conversation error: #{ err }"

	# Start (or continue) conversation and process responses
	processConversation: (msg, model, key, transcript) ->
		@logDebug "Conversation dialog completed"
		@ignoreIncoming = true
		@conversation.start msg, model, (err, msg, result) =>
			@ignoreIncoming = false
			return err if err

			# start transcript and add responses (or append if continuing)
			dialog = result.fetch()
			@logInfo "Recording transcript for #{ key } model"
			transcript ?= new Transcript dialog
			transcript.addResponses dialog.answers, model

			# see if any answers trigger another model
			hasNext = _.find dialog.answers, (response) ->
				return findResponseStep(response, model).next?
			nextKey = findResponseStep(hasNext, model).next if hasNext

			# continue conversation with next model
			if nextKey? and (nextModel = @models[nextKey])?
				@processConversation msg, nextModel, nextKey, transcript

			# end conversation
			else

				# send report if needed
				if model.reportRoom? and transcript.report.length
					@robot.messageRoom model.reportRoom, transcript.report.join(' ')

				# any last words?
				if model.onConclusion?
					@send msg, model, parseTemplate model.onConclusion, transcript.meta

	# Send a response according to the model privacy switch
	send: (msg, model, text) ->
		return msg.sendPrivate text if model.private
		return msg.send text

	# Shortcut log helpers
	logError: (message) -> @robot.logger.error message
	logDebug: (message) -> @robot.logger.debug message
	logInfo: (message) ->	@robot.logger.info message

# Transcript records outputs from a conversation instance
class Transcript
	constructor: (dialog) ->
		@meta =
			userName : dialog.source.name
			dateTime : dialog.dateTime
		@responses = []
		@report = []

	# collect responses and key/values to compile report templates
	addResponses: (responses, model) =>
		@responses.concat responses
		if model.report?
			_.each responses, (response) =>
				step = findResponseStep response, model
				return unless step?.key # no key for response
				@meta[step.key] = response.response.value
			for key, line of model.report
				@report.push parseTemplate line, @meta if @meta[key]?

module.exports = ConversationEngine

# TODO: refactor following with dynamic-conversation included in this class
# Takes a response object (returned by the dynamic-conversation session) and returns the
# corresponding section of original script.
findResponseStep = (response, model) ->
	i = 0
	while i < model?.conversation?.length
		# find a question in the original script that matches the question we're looking for
		if model.conversation[i].question == response?.question
			# is this a 'choice' question
			if model.conversation[i].answer?.type == 'choice'
				j = 0
				# now see if there's a matching answer amongst the choices
				while j < model.conversation[i].answer?.options?.length
					if response.response.value.match model.conversation[i].answer.options[j].match.toRegExp()
						# HACK! copy the parent key to the child, rather than replicating it in each YAML sub-branch
						if model.conversation[i].answer.key
							model.conversation[i].answer.options[j].key = model.conversation[i].answer.key
						return model.conversation[i].answer.options[j]
					j++
			else
				# if not, we just return the answer
				return model.conversation[i].answer
		i++
