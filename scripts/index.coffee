ConversationEngine = require '../conversation'

module.exports = (robot) ->
	engine = new ConversationEngine robot
	engine.readDir 'models'
	engine.registerAll()
