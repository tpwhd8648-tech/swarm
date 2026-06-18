'use strict'

angular.module('swarmApp').factory 'ProducerPath', ($log, UNIT_LIMIT) -> class ProducerPath
  constructor: (@unit, @path) ->
    pathname = _.map(@path, (p) => p.parent.name).join '>'
    # unit.name's in the name twice, just so there's no confusion about where the path ends
    @name = "#{@unit.name}:#{pathname}>#{@unit.name}"
  first: -> @path[0]
  isZero: -> @first().parent.count().isZero()
  degree: -> @path.length
  degreeOrZero: -> if @isZero() then 0 else @degree()
  prodEach: ->
    return @unit.game.cache.producerPathProdEach[@name] ?= do =>
      # Bonus for ancestor to produced-child == product of all bonuses along the path
      # (intuitively, if velocity and velocity-changes are doubled, acceleration is doubled too)
      # Quantity of buildings along the path do not matter, they're calculated separately.
      ret = new Decimal 1
      for ancestordata in @path
        val = new Decimal(ancestordata.prod.val).plus ancestordata.parent.stat 'base', 0
        ret = ret.times val
        ret = ret.times ancestordata.parent.stat 'prod', 1
        # Cap ret, just like count(). This prevents Infinity * 0 = NaN problems, too.
        ret = Decimal.min ret, UNIT_LIMIT
      return ret
  coefficient: (count=@first().parent.rawCount()) ->
    # floor(): no fractional units. #184
    count.floor().times @prodEach()
  coefficientNow: ->
    @coefficient @first().parent.count()
  count: (secs) ->
    degree = @degree()
    coeff = @coefficient()
    # c * (t^d)/d!
    return coeff.times(Decimal.pow(secs, degree)).dividedBy(math.factorial degree)

angular.module('swarmApp').factory 'ProducerPaths', ($log, ProducerPath) -> class ProducerPaths
  constructor: (@unit, @raw) ->
    @list = _.map @raw, (path) =>
      tailpath = path.concat [@unit]
      return new ProducerPath @unit, _.map path, (parent, index) =>
        child = tailpath[index+1]
        prodlink = parent.prodByName[child.name]
        parent:parent
        child:child
        prod:prodlink
    @byDegree = _.groupBy @list, (path) ->
      path.degree()

  getDegreeCoefficient: (degree, now=false) ->
    ret = new Decimal 0
    for path in @byDegree[degree] ? []
      ret = ret.plus if now then path.coefficientNow() else path.coefficient()
    return ret

  # Highest polynomial degree of this unit's production chain where the ancestor has nonzero count.
  # Or, how many parents it has. Examples of degree:
  #
  # [drone] is degree 0 (constant, rawcount() with no time factor)
  # [drone > meat] is degree 1
  # [queen > drone > meat] is degree 2
  # [nest > queen > drone > meat] is degree 3
  # [nest > queen > drone] is degree 2
  getMaxDegree: ->
    return @getCoefficients().length - 1

  getCoefficients: ->
    return @unit.game.cache.producerPathCoefficients[@unit.name] ?= @_getCoefficients()

  _getCoefficients: (now=false) ->
    # array indexes are polynomial degrees, values are coefficients
    # [1, 3, 5, 7] = 7t^3 + 5t^2 + 3t + 1
    ret = [if now then @unit.count() else @unit.rawCount()]
    for pathdata in @list
      degree = pathdata.degree()
      coefficient = if now then pathdata.coefficientNow() else pathdata.coefficient()
      if not coefficient.isZero()
        ret[degree] = (ret[degree] ? new Decimal 0).plus coefficient
    for coeff, degree in ret
      if not coeff?
        ret[degree] = new Decimal 0
    return ret

  getCoefficientsNow: ->
    return @_getCoefficients true
  
  count: (secs) ->
    # Horner's method should be faster here:
    # https://en.wikipedia.org/wiki/Horner's_method
    # http://jsbin.com/doqudoxopo/edit?html,output
    # ...but I tried it and it wasn't.
    ret = new Decimal 0
    for coeff, degree in @getCoefficients()
      # c * (t^d)/d!
      ret = ret.plus coeff.times(Decimal.pow(secs, degree)).dividedBy(math.factorial degree)
    return ret

angular.module('swarmApp').factory 'Unit', (util, $log, Effect, ProducerPaths, UNIT_LIMIT) -> class Unit
  # TODO unit.unittype is needlessly long, rename to unit.type
  constructor: (@game, @unittype) ->
    @name = @unittype.name
    @suffix = ''
    @affectedBy = []
    @type = @unittype # start transitioning now
  # --- CUSTOM BALANCE MULTIPLIER ---
  # All production rates are multiplied by RESOURCE_GAIN_MULTIPLIER,
  # and all costs are divided by the same factor, so the player gathers
  # resources 1000x faster and everything is 1000x cheaper to buy.
  RESOURCE_GAIN_MULTIPLIER: 1000

  _init: ->
    @prod = _.map @unittype.prod, (prod) =>
      ret = _.clone prod
      ret.unit = @game.unit prod.unittype
      ret.val = new Decimal(ret.val).times @RESOURCE_GAIN_MULTIPLIER
      return ret
    @prodByName = _.keyBy @prod, (prod) -> prod.unit.name
    @cost = _.map @unittype.cost, (cost) =>
      ret = _.clone cost
      ret.unit = @game.unit cost.unittype
      ret.val = new Decimal(ret.val).dividedBy @RESOURCE_GAIN_MULTIPLIER
      return ret
    @costByName = _.keyBy @cost, (cost) -> cost.unit.name
    @warnfirst = _.map @unittype.warnfirst, (warnfirst) =>
      ret = _.clone warnfirst
      ret.unit = @game.unit warnfirst.unittype
      return ret
    @showparent = @game.unit @unittype.showparent
    @upgrades =
      list: (upgrade for upgrade in @game.upgradelist() when @unittype == upgrade.type.unittype or @showparent?.unittype == upgrade.type.unittype)
    @upgrades.byName = _.keyBy @upgrades.list, 'name'
    @upgrades.byClass = _.groupBy @upgrades.list, (u) -> u.type.class

    @requires = _.map @unittype.requires, (require) =>
      util.assert require.unittype or require.upgradetype, 'unit require without a unittype or upgradetype', @name, name, require
      util.assert not (require.unittype and require.upgradetype), 'unit require with both unittype and upgradetype', @name, name, require
      ret = _.clone require
      ret.val = new Decimal ret.val
      if require.unittype?
        ret.resource = ret.unit = util.assert @game.unit require.unittype
      if require.upgradetype?
        ret.resource = ret.upgrade = util.assert @game.upgrade require.upgradetype
      return ret
    @cap = _.map @unittype.cap, (capspec) =>
      ret = _.clone capspec
      ret.unit = @game.unit ret.unittype
      ret.val = new Decimal ret.val
      return ret
    @effect = _.map @unittype.effect, (effect) =>
      ret = new Effect @game, this, effect
      ret.unit.affectedBy.push ret
      return ret

    @tab = @game.tabs.byName[@unittype.tab]
    if @tab
      @next = @tab.next this
      @prev = @tab.prev this
  # hacky, but we need two stages of init() for our object graph: all unit->unittype, all prod->unit, all producerpath->prod
  _init2: ->
    # copy all the inter-unittype references, replacing the type references with units
    @_producerPath = new ProducerPaths this, _.map @unittype.producerPathList, (path) =>
      _.map path, (unittype) =>
        ret = @game.unit unittype
        util.assert ret
        return ret

  isCountInitialized: ->
    return @game.session.state.unittypes[@name]?
  rawCount: ->
    return @game.cache.unitRawCount[@name] ?= do =>
      # caching's helpful to avoid re-parsing session strings
      ret = @game.session.state.unittypes[@name] ? 0
      if _.isNaN ret
        util.error 'NaN count. oops.', @name, ret
        ret = 0
      # toPrecision avoids Decimal errors when converting old saves
      if _.isNumber ret
        ret = ret.toPrecision 15
      return new Decimal ret
  _setCount: (val) ->
    @game.session.state.unittypes[@name] = new Decimal val
    @game.cache.onUpdate()
  _addCount: (val) ->
    @_setCount @rawCount().plus(val)
  _subtractCount: (val) ->
    @_addCount new Decimal(val).times(-1)

  # direct parents, not grandparents/etc. Drone is parent of meat; queen is parent of drone; queen is not parent of meat.
  _parents: ->
    (pathdata.first().parent for pathdata in @_producerPath.list when pathdata.first().parent.prodByName[@name])

  _getCap: ->
    return @game.cache.unitCap[@name] ?= do =>
      if @hasStat 'capBase'
        ret = @stat 'capBase'
        ret = ret.times @stat 'capMult', 1
        ret = ret.plus @stat 'capFlat', 0
        return ret
  capValue: (val) ->
    cap = @_getCap()
    if not cap?
      # if both are undefined, prefer undefined to NaN, mostly for legacy
      if not val?
        return val
      return Decimal.min val, UNIT_LIMIT
    if not val?
      # no value supplied - return just the cap
      return cap
    return Decimal.min val, cap

  capPercent: ->
    if (cap = @capValue())?
      return @count().dividedBy(cap)
  capDurationSeconds: ->
    if (cap = @capValue())?
      return @estimateSecsUntilEarned(cap).toNumber?() ? 0
  capDurationMoment: ->
    if (secs = @capDurationSeconds())?
      return moment.duration secs, 'seconds'

  isVisible: ->
    return @game.cache.unitVisible[@name] ?= do =>
      return true if @hasUnlimitedVisibility()
      return true if @isCountInitialized() and @rawCount().greaterThan 0
      return true if @velocity().greaterThan 0
      return @isAllRequiresMet()

  hasUnlimitedVisibility: ->
    return @unittype.visible == 'always'

  isAllRequiresMet: ->
    return true if @requires.length == 0
    op = @unittype.requiresOp ? 'AND'
    for require in @requires
      met = @isRequireMet require
      if op == 'AND' and not met
        return false
      else if op == 'OR' and met
        return true
    return op == 'AND'

  isRequireMet: (require) ->
    if require.unit?
      return require.unit.rawCount().greaterThanOrEqualTo require.val
    if require.upgrade?
      return require.upgrade.isPurchased()
    return false

  estimateSecsUntilEarned: (target, fromCount=@rawCount()) ->
    # binary-search for the time at which we'll reach the target count
    diff = target.minus fromCount
    return new Decimal 0 if diff.lessThanOrEqualTo 0
    lo = new Decimal 0
    hi = new Decimal 1
    while @_producerPath.count(hi).lessThan diff
      hi = hi.times 2
      return new Decimal Infinity if hi.greaterThan UNIT_LIMIT
    for i in [0...100]
      mid = lo.plus(hi).dividedBy 2
      if @_producerPath.count(mid).lessThan diff
        lo = mid
      else
        hi = mid
    return hi

  _costMetPercent: ->
    return @game.cache.unitCostMetPercent[@name] ?= do =>
      eachCost = @eachCost()
      return new Decimal 0 if eachCost.length == 0
      ret = new Decimal Infinity
      for cost in eachCost
        have = cost.unit.rawCount()
        ret = Decimal.min ret, have.dividedBy cost.val
      return ret

  _costMetPercentOfVelocity: ->
    eachCost = @eachCost()
    return new Decimal 0 if eachCost.length == 0
    ret = new Decimal Infinity
    for cost in eachCost
      have = cost.unit.velocity()
      ret = Decimal.min ret, have.dividedBy cost.val
    return ret

  isBuyButtonVisible: ->
    eachCost = @eachCost()
    if @unittype.unbuyable or eachCost.length == 0
      return false
    for cost in eachCost
      if not cost.unit.isVisible()
        return false
    return true

  maxCostMet: (percent=1) ->
    return @game.cache.unitMaxCostMet["#{@name}:#{percent}"] ?= do =>
      @_costMetPercent().times(percent).floor()
      
  maxCostMetOfVelocity: () ->
    return @game.cache.unitMaxCostMetOfVelocity["#{@name}"] ?= do =>
      @_costMetPercentOfVelocity()
  
  maxCostMetOfVelocityReciprocal: () ->
    (new Decimal 1).dividedBy(@maxCostMetOfVelocity())

  isCostMet: ->
    @maxCostMet().greaterThan 0

  isBuyable: (ignoreCost=false) ->
    return (@isCostMet() or ignoreCost) and @isBuyButtonVisible() and not @unittype.unbuyable

  buyMax: (percent) ->
    @buy @maxCostMet percent

  twinMult: ->
    ret = new Decimal 1
    ret = ret.plus @stat 'twinbase', 0
    ret = ret.times @stat 'twin', 1
    return ret
  buy: (num=1) ->
    if not @isCostMet()
      throw new Error "We require more resources"
    if not @isBuyable()
      throw new Error "Cannot buy that unit"
    num = Decimal.min num, @maxCostMet()
    @game.withSave =>
      for cost in @eachCost()
        cost.unit._subtractCount cost.val.times num
      twinnum = num.times @twinMult()
      @_addCount twinnum
      for effect in @effect
        effect.onBuyUnit twinnum
      # This is a hideous hack that really should be an addUnits effect, but it starts an infinite loop (energy -> mtxEnergy -> energy-cap -> energy...) that I really can't be arsed to debug this late into swarmsim's life.
      if @name == 'energy'
        @game.unit('mtxEnergy')._addCount twinnum
      return {num:num, twinnum:twinnum}

  isNewlyUpgradable: ->
    upgrades = @showparent?.upgrades?.list ? @upgrades.list
    _.some upgrades, (upgrade) ->
      upgrade.isVisible() and upgrade.isNewlyUpgradable()

  totalProduction: ->
    return @game.cache.totalProduction[@name] ?= do =>
      ret = {}
      count = @count().floor()
      for key, val of @eachProduction()
        ret[key] = val.times count
      return ret

  eachProduction: ->
    return @game.cache.eachProduction[@name] ?= do =>
      ret = {}
      for prod in @prod
        ret[prod.unit.unittype.name] = (prod.val.plus @stat 'base', 0).times @stat 'prod', 1
      return ret

  eachCost: ->
    return @game.cache.eachCost[@name] ?= _.map @cost, (cost) =>
      cost = _.clone cost
      cost.val = cost.val.times(@stat 'cost', 1).times(@stat "cost.#{cost.unit.unittype.name}", 1)
      return cost

  # speed at which other units are producing this unit.
  velocity: ->
    return @game.cache.velocity[@name] ?= Decimal.min UNIT_LIMIT, @_producerPath.getDegreeCoefficient(1, true)

  isVelocityConstant: ->
    return @_producerPath.getMaxCoefficient() <= 1

  # TODO rework this - shouldn't have to pass a default
  hasStat: (key, default_=undefined) ->
    @stats()[key]? and @stats()[key] != default_
  stat: (key, default_=undefined) ->
    util.assert key?
    if default_?
      default_ = new Decimal default_
    ret = @stats()[key] ? default_
    util.assert ret?, 'no such stat', @name, key
    return new Decimal ret
  stats: ->
    return @game.cache.stats[@name] ?= do =>
      stats = {}
      schema = {}
      for upgrade in @upgrades.list
        upgrade.calcStats stats, schema
      for uniteffect in @affectedBy
        uniteffect.calcStats stats, schema, uniteffect.parent.count()
      return stats

  statistics: ->
    @game.session.state.statistics?.byUnit?[@name] ? {}

  # TODO centralize url handling
  url: ->
    @tab.url this

  # for the addUnitTimed effect
  addUnitTimer: ->
    key = "addUnitTimed-#{@name}"
    return @game.session.state.date[key] ? new Date 0
  addUnitTimerElapsedMillis: (now=@game.now) ->
    return now.getTime() - @addUnitTimer().getTime()
  addUnitTimerRemainingMillis: (durationMillis, now=@game.now) ->
    return Math.max 0, durationMillis - @addUnitTimerElapsedMillis(now)
  isAddUnitTimerReady: (durationMillis, now=@game.now) ->
    return @addUnitTimerRemainingMillis(durationMillis) == 0
  setAddUnitTimer: (now=@game.now) ->
    key = "addUnitTimed-#{@name}"
    @game.session.state.date[key] = now
    util.assert @addUnitTimerElapsedMillis(now) == 0

###*
 # @ngdoc service
 # @name swarmApp.unittypes
 # @description
 # # unittypes
 # Factory in the swarmApp.
###
angular.module('swarmApp').factory 'UnitType', -> class Unit
  constructor: (data) ->
    _.extend this, data
    @producerPath = {}
    @producerPathList = []

  producerNames: ->
    _.mapValues @producerPath, (paths) ->
      _.map paths, (path) ->
        _.map path, 'name'

angular.module('swarmApp').factory 'UnitTypes', (spreadsheetUtil, UnitType, util, $log) -> class UnitTypes
  constructor: (unittypes=[]) ->
    @list = []
    @byName = {}
    for unittype in unittypes
      @register unittype

  register: (unittype) ->
    @list.push unittype
    @byName[unittype.name] = unittype

  @_buildProducerPath = (unittype, producer, path) ->
    path = [producer].concat path
    unittype.producerPathList.push path
    unittype.producerPath[producer.name] ?= []
    unittype.producerPath[producer.name].push path
    for nextgen in producer.producedBy
      @_buildProducerPath unittype, nextgen, path

  @parseSpreadsheet: (effecttypes, data) ->
    rows = spreadsheetUtil.parseRows {name:['cost','prod','warnfirst','requires','cap','effect']}, data.data.unittypes.elements
    ret = new UnitTypes (new UnitType(row) for row in rows)
    for unittype in ret.list
      unittype.producedBy = []
      unittype.affectedBy = []
    for unittype in ret.list
      #unittype.tick = if unittype.tick then moment.duration unittype.tick else null
      #unittype.cooldown = if unittype.cooldown then moment.duration unittype.cooldown else null
      # replace names with refs
      if unittype.showparent
        spreadsheetUtil.resolveList [unittype], 'showparent', ret.byName
      spreadsheetUtil.resolveList unittype.cost, 'unittype', ret.byName
      spreadsheetUtil.resolveList unittype.prod, 'unittype', ret.byName
      spreadsheetUtil.resolveList unittype.warnfirst, 'unittype', ret.byName
      spreadsheetUtil.resolveList unittype.requires, 'unittype', ret.byName, {required:false}
      spreadsheetUtil.resolveList unittype.cap, 'unittype', ret.byName, {required:false}
      spreadsheetUtil.resolveList unittype.effect, 'unittype', ret.byName
      spreadsheetUtil.resolveList unittype.effect, 'type', effecttypes.byName
      # oops - we haven't parsed upgradetypes yet! done in upgradetype.coffee.
      #spreadsheetUtil.resolveList unittype.require, 'upgradetype', ret.byName
      unittype.slug = unittype.label
      for prod in unittype.prod
        prod.unittype.producedBy.push unittype
        util.assert prod.val > 0, "unittype prod.val must be positive", prod
      for cost in unittype.cost
        util.assert cost.val > 0 or (unittype.unbuyable and unittype.disabled), "unittype cost.val must be positive", cost
    for unittype in ret.list
      for producer in unittype.producedBy
        @_buildProducerPath unittype, producer, []
    $log.debug 'built unittypes', ret
    return ret

###*
 # @ngdoc service
 # @name swarmApp.units
 # @description
 # # units
 # Service in the swarmApp.
###
angular.module('swarmApp').factory 'unittypes', (UnitTypes, effecttypes, spreadsheet) ->
  return UnitTypes.parseSpreadsheet effecttypes, spreadsheet
