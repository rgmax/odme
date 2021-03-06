Base = require './base'
Boom = require 'boom'
_    = require 'lodash'
Promise = require 'bluebird'
es = require 'elasticsearch'

# ## Model Layer Using [puffer library](https://www.npmjs.com/package/puffer)
#
# This Model class is using puffer for CRUDing. It's recommended to read [puffer's documentation](https://www.npmjs.com/package/puffer) first.
# @param {object} this is the port, host, index name of elasticsearch and source of base.
# @param {object} this is the elastic search client. if client is not passed one is created from config
module.exports = (@config, @client) ->
  return class CB extends Base

    source: config.source

    # ## Get
    #
    # Get the existing doc by key and instantiate an ODME object. The returned object has `.is_new` property set to `false`. If you don't need the ODME object and only need the doc to work with, you should pass `true` as the second parameter which will return the raw Couchbase Document and it's slightly faster.
    #
    # If you pass an array list of keys, it can get all those documents, only if they all exists.
    #
    # @method get(key[, raw])
    # @public
    #
    # @param {string}  key(s)  document key(s) which should be retrieved
    # @param {boolean} raw  if it should return raw document
    #
    # @example
    #   recipe.get('recipe_uX87dkF3Bj').then (d) -> console.log d
    #
    @get: (key, raw)->
      return Promise.resolve( if _.isArray(key) then [] else null) if _.isEmpty key or _.isNaN key
      raw ||= false
      make = (key, document) =>
        instance = new @ document, key
        instance.doc = document.value
        instance.cas = document.cas
        instance.key = key
        instance.is_new = false
        instance
      @::source.get(key).then (document)->
        return document if document.isBoom || raw
        if key not instanceof Array
          return make( key, document )
        list = []
        for i in key
          list.push make( i, document[i] )
        list

    # ## Find
    #
    # Find the existing doc by key (it can get list of keys as well). It can return raw Couchbase Document or the masked version of it. It uses **props** or **_mask** as default filter unless you pass the a string of mask as second parameter.
    #
    # @method find(key[, raw[, as_object]])
    # @public
    #
    # @param {string}         key(s)     document key(s) which should be retrieved
    # @param {boolean|string} raw        if it's true it returns raw document, if it is string, it will be considered as a mask. Default is false and it will mask the document
    # @param {boolean}        as_object  this property only works if the `raw` parameter is set to false. If it's true, it converts the array list of documents to the object, which means you can find a doc by it's `doc_key` in that object. It helps you to access documents in the result set by their keys.
    #
    # @example
    #   recipe.find('recipe_uX87dkF3Bj').then (d) -> console.log d
    #
    @find: (key, raw, asObject)->
      return Promise.resolve( if _.isArray(key) then [] else null) if _.isEmpty key or _.isNaN key
      @::source.get(key, true).then (d)=>
        return d if d.isBoom || (raw? && raw == true)
        mask = (@::_mask||null)
        mask = raw if typeof raw == 'string'
        if key not instanceof Array
          if asObject? and asObject
            (o = {})[d.docKey] = @mask d, mask
            return o
          else
            return @mask d, mask
        else
          if asObject? and asObject
            list = {}
            for i in d
              list[i.docKey] = @mask i, mask
          else
            list = []
            for i in d
              list.push @mask i, mask
          list

    # ## Mask or Data
    #
    # Check the CB callback's result and make sure there was no error. If so and masked version is requested, it will return the masked result.
    #
    # @method maskOrData(data[, mask])
    # @private
    #
    # @param {string|array|true}           mask  this works exactly same way mask(mask) method works
    #
    maskOrData: (data, mask)->
      if data.isBoom
        data
      else if ! mask
        @mask @_mask
      else
        @mask mask

    # ## Create
    #
    # Create the doc in assigned key. It can return masked doc after creating.
    #
    # Creation will only work if both `beforeCreate` and `beforeSave` return true (which they do by default unless you override them). You can use these methods to add your pre-creation logic to change the document or use them as validations.
    #
    # After creating the doc, `afterSave` and `afterCreate` methods will be called. These are useful when you want to execute post creation logic.
    #
    # @method create([mask])
    # @public
    #
    # @param {string|array|true}           mask  this works same as mask(mask) method.
    #
    # @example
    #   recipe = new Recipe { name: 'Pasta', origin: 'Italy' }
    #   recipe.doc.popularity = 100
    #   recipe.create(true).then (d) -> console.log d
    #
    create: (mask) ->
      @lifeCycle(mask, "Create", () => @source.insert(@key, @doc))


    # ## Handles callbacks
    #
    # calls the before and after callbaks of create and update
    lifeCycle: (mask, type, fn) ->
      before = Promise.method(@["before#{type}"].bind(@))
      beforeSave = Promise.method(@beforeSave.bind(@))
      afterSave = Promise.method(@afterSave.bind(@))
      after = Promise.method(@["after#{type}"].bind(@))
      before()
        .then (passed) =>
          throw passed if passed isnt true
          beforeSave()
        .then (passed) =>
          throw passed if passed isnt true
          @validateDoc()
          fn(mask)
        .then (data) =>
          @maskOrData(data, mask)
        .then (data) =>
          afterSave(data)
        .then (data) =>
          after(data)
        .catch (err) ->
          if err instanceof Error
            err
          else
            Boom.notAcceptable "Validation failed"



    # ## Update
    #
    # Update an existing doc using its key. It can return masked doc after saving and works in 2 different way:
    #
    # ### Get the document and update it
    #
    # You can get the document which means you have access to `.doc` property in the ODME object and all your pre-update callbacks can use the `.doc`. Once you are done with the ODME object you can call update and it will replace your `.doc` with the version in Data Storage.
    #
    # ```
    #   Recipe.get("recipe_xhygd12gH3").then (recipe) ->
    #     recipe.doc.name = 'Pasta'
    #     recipe.update()
    # ```
    #
    # ### Update a document using a new ODME object
    #
    # You instantiate a new ODME object with the key of previously stored docuemnt and assign your proeprties to its `.doc`. When `.update()` method is called, it will replace get the old doc internally and merge your new properties into it.
    #
    # ```
    #   recipe = new Recipe { name: 'Pasta' }, "recipe_xhygd12gH3"
    #   recipe.update()
    #
    # ```
    #
    # **Note:** Remember update works asynchronously, therefore if you want to do some actions after it you should define them in `.then`.
    #
    # Same as `create` method we have `beforeUpdate`, `beforeSave`, `afterSave` and `afterUpdate` callbacks hooked to update.
    #
    # @method update([mask])
    # @public
    #
    # @param {string|array|true}           mask  this works same as mask(mask) method.
    #
    # @example
    #   recipe = new Recipe "recipe_xhygd12gH3", { name: 'Anti Pasta' }
    #   recipe.update(true).then (d) -> console.log d
    #
    update: (mask) ->
      @lifeCycle mask, "Update", (mask) =>
        update =
          if @is_new
            @source.update @key, @doc
          else
            @source.replace @key, @doc, { cas: @cas }
        update
          .then (data) =>
            return data if data.isBoom
            @source.get(@key, true)
              .then (result) =>
                @doc = result
                result

    # ## Delete
    #
    # Delete the existing doc by key. It return true or the error object
    #
    # @method remove(key)
    # @public
    #
    # @param {string}  key  document key which should be removed
    #
    # @example
    #   Recipe.remove('recipe_UYd3f1Ty65').then (d) -> console.log d
    #
    @remove: (key)->
      @::source.remove(key)
        .then (data)->
          return data if data.isBoom
          return true

    # ## Before update Callback
    #
    # Before Update can be used to assign values or as validation. It should return true to update the doc. If it returns false, ODME will return Boom Error. If you want to have your own error message make sure you are returning a Boom Error object at the end of this method on failures.
    #
    beforeUpdate: -> return true

    # ## Before create Callback
    #
    # Before Create can be used to assign values or as validation. It should return true to create the doc. If it returns false, ODME will return Boom Error. If you want to have your own error message make sure you are returning a Boom Error object at the end of this method on failures.
    #
    beforeCreate: -> return true

    # ## Before save Callback
    #
    # Before Save can be used to assign values or as validation. It should return true to create/update the doc. If it returns false, ODME will return Boom Error. If you want to have your own error message make sure you are returning a Boom Error object at the end of this method on failures.
    #
    beforeSave: -> return true

    # ## After Create Callback
    #
    # After create hook to do extra processing on the result. If you want the data being passed in promises chain after calling **afterCreate** make sure you are returning it. `afterCreate` callback will be called before this.
    #
    afterCreate: (data) -> return data

    # ## After Update Callback
    #
    # Override after update callback in your models. If you want the data being passed in promises chain after calling **afterUpdate** make sure you are returning it. This will be called only after update.
    #
    afterUpdate: (data) -> return data

    # ## After Save Callback
    #
    # Override save callback in your models. If you want the data being passed in promises chain after calling **afterSave** make sure you are returning it. This will be called after create and update.
    #
    afterSave: (data) -> return data

    # ## Handle elasticsearch data
    # this will handle the heavy lifting of getting the data you want in the format that you desire
    # @param {string} return result of Elastic query
    # @param {options} the same options that is passed to @search method
    @handleElasticData: (data, options = {}) ->
      new Promise (resolve) =>
        total = data.hits.total
        if options.keysOnly is true
          list = _.map(data.hits.hits, "_id")
          resolve {total, list} if options.format is true
          resolve list
        if options.couchbaseDocuments is true
          @find(_.map(data.hits.hits, "_id"), options.mask)
            .then (documents) ->
              resolve {total, list: documents} if options.format is true
              resolve documents
        else
          list = _.map(data.hits.hits, (o) -> return o._source.doc)
          resolve {total, list} if options.format is true
          resolve list

    # ## Query Elastic
    #
    # @param {string} which type of document should elastic query
    # @param {object} the query itself
    # @param {object} there many field you can set in options field: searchType specifies the search type that ES should use for example count, keysOnly will return only the doc_keys of the documents, format will return the documents and the total number of them, setting couchbaseDocuments to true will return get the list from couchbase, mask will mask the result of data that is returned by CB
    @search: (type, query, options = {}) ->
      throw 'config cannot be empty' unless config?
      query.index = config.index
      query.type = type
      query.search_type = options.searchType if options.searchType?
      unless client?
        client = new es.Client
          host: "#{config.host}:#{config.port}"
      client.search(query)
        .then (result) =>
          @handleElasticData(result, options)
        .catch (err) ->
          throw err
