
$(document).ready ->

  $("#guide").fadeIn(750)

  require './string'
  socket = io.connect window.location
  views = new Views()
  controller = new Controller(socket, views)
  document.signage =
    views: views
    controller: controller

  socket.on 'screen',
    (data) ->
      document.signage.controller.set_screen(data)

  socket.on 'update',
    (data) ->
      document.signage.controller.update(data)

  socket.on 'remove',
    (data) ->
      document.signage.controller.remove(data['key'])

  socket.on 'empty',
    (data) ->
      console.log 'empty received'
      console.log data

  socket.on 'error',
    (data) ->
      console.log 'error received'
      console.log data

  socket.on 'speed',
    (data) ->
      document.signage.controller.set_speed(data)

  socket.on 'reload',
    (data) ->
      window.location.reload()


class Controller

  constructor: (socket, views) ->
    @socket = socket
    @views = views
    @queue = []
    @min_buffer_size = 10
    @max_buffer_size = 20
    @range = (12 * 24 * 60 * 60 * 1000) # 12 days
    @screen = {}
    @position = 0
    @additions = []
    @removals = []
    @interval = null
    @timeout = null
    @seconds = (if window.location.href.match(/\:3000/) then 2 else 9)
    @blocked = false

  running: () ->
    return true if @interval?
    false

  waiting: () ->
    return true if @timeout?
    false

  set_screen: (screen) ->
    @screen = screen
    @buffer()

  set_speed: (data) ->
    seconds = parseInt(data['seconds'])
    if !isNaN(seconds)
      @seconds = seconds
      clearInterval @interval
      @interval = setInterval("document.signage.controller.next()", (@seconds * 1000))

  stop: () ->
    clearInterval @interval
  
  has: (key, queue = @queue) ->
    for queued, index in queue
      return index if key is queued['key']
    null

  is_dst: (d) -> # from: http://www.mresoftware.com/simpleDST.htm
    year = d.getFullYear()
    dst_start = new Date("March 14, #{year} 02:00:00") # 2nd Sunday in March can't occur after the 14th 
    dst_end = new Date("November 07, #{year} 02:00:00") # 1st Sunday in November can't occur after the 7th
    day = dst_start.getDay() # day of week of 14th
    dst_start.setDate(14 - day) # Calculate 2nd Sunday in March of year in question
    day = dst_end.getDay() # day of the week of 7th
    dst_end.setDate(7 - day) # Calculate first Sunday in November of year in question
    return true if d >= dst_start and d < dst_end # does today fall inside of DST period?
    false

  date: (value) ->
    d = new Date(Date.parse(value))
    d.setTime(d.getTime() + (60 * 60 * 1000)) if not @is_dst(d)
    d

  datify: (item) ->
    for property, value of item
      item[property] = @date(value) if typeof value is 'string' and value.match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
    item

  qrcodify: (key, link) ->
    object = @
    $.ajax({
      url: 'http://api.bitly.com/v3/shorten?login=lcweblab&apiKey=R_6b2425f485649afae898025bcd17458d&longUrl=' + encodeURI(link) + '&format=json'
      method: 'GET'
      dataType: 'json'
      success: (data, textStatus, jqXHR) ->
        if data? and data.data? and data.data.url?
          index = object.has(key)
          object.queue[index]['item']['qrcode'] = data.data.url if index?
        else if data? and data.status_code? and data.status_txt?
          object.socket.emit 'error', { screen: object.screen, error: "qrcodify.ajax.error: #{data.status_code} #{data.status_txt}" }
      error: (jqXHR, textStatus, errorThrown) ->
        object.socket.emit 'error', { screen: object.screen, error: "qrcodify.ajax.error: #{textStatus} #{errorThrown}" }
    })

  is_live: (item) ->
    return true if item['status'] is 1
    false

  has_matching_channel: (item) ->
    return true if (not item['channels']?)
    return true if item['channels'].indexOf(@screen['channel']) >= 0
    false

  is_in_range: (item) ->
    d = new Date()
    return true if item['start_time'].getTime() < d.getTime() + @range
    false

  insert_index: (data) ->
    return 0 if @queue.length is 0
    for queued, index in @queue
      return index if data['item']['start_time'].getTime() < queued['item']['start_time'].getTime()
    return @queue.length if @queue.length < @max_buffer_size
    null

  update: (data) ->
    try
      data['item'] = JSON.parse data['item']
      data['item'] = @datify(data['item'])
      exists = @has(data['key'])
      if exists?
        @queue[exists] = data
        @qrcodify(data['key'], data['item']['link']) if (not data['item']['qrcode']?)
      else if @is_live(data['item']) and @has_matching_channel(data['item']) and @is_in_range(data['item'])
        if !@running()
          @queue.push data
          @qrcodify(data['key'], data['item']['link']) if (not data['item']['qrcode']?)
        else
          index = @has(data['key'], @additions)
          if index?
            @additions[index] = data
          else
            @additions.push data
      @timeout = setTimeout("document.signage.controller.begin()", (@seconds * 1000)) if !@running() and !@waiting()
    catch e
      console.log e

  remove: (key) ->
    @removals.push key

  buffer: () ->
    return if @queue.length >= @max_buffer_size
    @socket.emit 'items', { count: (@max_buffer_size - @queue.length) }

  begin: () ->
    $("#guide").fadeOut(750)
    @render()
    @interval = setInterval("document.signage.controller.next()", (@seconds * 1000))

  next: () ->
    if @position is -1
      $("#guide").fadeOut(750)
    @position += 1
    if @position >= @queue.length
      @reset()
    else
      @render()

  refresh_queue: () ->
    if @additions.length > 0 or @removals.length > 0
      @blocked = true
      if @removals.length > 0
        new_queue = []
        @socket.emit 'log', { screen: @screen, log: "refresh_queue: removals length #{@removals.length}" }
        for key in @removals
          index = @has(key)
          if index?
            for i in [0..@queue.length-1]
              if i isnt index
                new_queue.push $.extend({}, item[i])
        @queue = $.extend(true, [], new_queue)
        @removals = []
      if @additions.length > 0
        new_queue = []
        @socket.emit 'log', { screen: @screen, log: "refresh_queue: additions length #{@additions.length}" }
        for addition in @additions
          index = @insert_index(addition)
          if index?
            for i in [0..@queue.length]
              if i < index
                new_queue.push $.extend({}, item[i])
              else if i is index
                new_queue.push addition
              else
                new_queue.push $.extend({}, item[i-1])
            @qrcodify(addition['key'], addition['item']['link']) if (not addition['item']['qrcode']?)
        @queue = $.extend(true, [], new_queue)
        @additions = []
      @blocked = false

  reset: () ->
    $("#guide").fadeIn(750)
    $("#announcements").html('').css('left', 0)
    @position = -1
    for addition in @additions
      exists = @has(addition['key'])
      if exists is null
        index = @insert_index(addition)
        if index?
          @queue.splice(index, 0, addition)
          @qrcodify(addition['key'], addition['item']['link']) if (not addition['item']['qrcode']?)
      else
        @queue[exists] = addition
    @additions = []
    for queued in @queue
      @removals.push(queued['key']) if @is_past(queued['item'])
      @removals.push(queued['key']) if not @is_in_range(queued['item'])
    for key in @removals
      index = @has(key)
      @queue.splice(index, 1) if index?
    @buffer() if @removals.length > 0 # or @queue.length < @min_buffer_size
    @removals = []
    # @refresh_queue()

  is_all_day: (item) ->
    return false if item['start_time'].getHours() isnt 0 or item['start_time'].getMinutes() isnt 0
    return true if item['end_time'] is null
    return false if item['end_time'].getHours() isnt 0 or item['end_time'].getMinutes() isnt 0
    true

  is_past: (item) ->
    d = new Date()
    return false if item['start_time'].getTime() > d.getTime()
    return true if @is_all_day(item) and d.getHours() > 20 # past eight p.m. if all day
    return true if item['end_time']? and d.getTime() > (item['start_time'].getTime() + (item['end_time'].getTime() - item['start_time'].getTime())/4) # past 25% of allotted time if end time
    return true if d.getTime() > (item['start_time'].getTime() + 900000) # past fifteen minutes after the event start time
    false

  render: () ->
    @views.render(@position, @queue[@position])
    @socket.emit 'impression', { screen: @screen, key: @queue[@position]['key'] }

  end: () ->
    clearInterval @interval


class Views

  constructor: () ->
    @screenWidth = $(window).width()
    @screenHeight = $(window).height()
    @days = [
      'Sunday'
      'Monday'
      'Tuesday'
      'Wednesday'
      'Thursday'
      'Friday'
      'Saturday'
      ]
    @months = [
      'Jan.'
      'Feb.'
      'Mar.'
      'Apr.'
      'May'
      'June'
      'July'
      'Aug.'
      'Sept.'
      'Oct.'
      'Nov.'
      'Dec.'
      ]

  pad: (n) ->
    return '0' + n if n < 10
    return n

  is_today: (d) ->
    now = new Date()
    (@is_this_week(d) and d.getDay() is now.getDay())

  is_tomorrow: (d) ->
    now = new Date()
    (@is_this_week(d) and ((d.getDay() - 1) is now.getDay() or (d.getDay() is 0 and now.getDay() is 6)))

  is_this_week: (d) ->
    now = new Date()
    ((d.getTime() - now.getTime()) < (6 * 24 * 60 * 60 * 1000))

  day_css: (d) ->
    return '' if not @is_this_week(d)
    return ' today' if @is_today(d)
    return ' tomorrow' if @is_tomorrow(d)
    ' within-a-week'

  day_for: (d) ->  
    return 'Today' if @is_today(d)
    return 'Tomorrow' if @is_tomorrow(d)
    return @days[d.getDay()] if @is_this_week(d)
    "#{@months[d.getMonth()]} #{d.getDate()}"

  format_time: (d, meridian=true) ->
    return "Midnight" if @is_midnight(d)
    return "Noon" if @is_noon(d)
    return "#{(d.getHours() - 12)}:#{@pad(d.getMinutes())}#{(if meridian then ' p.m.' else '')}" if d.getHours() > 12
    return "#{d.getHours()}:#{@pad(d.getMinutes())}#{(if meridian then ' p.m.' else '')}" if d.getHours() is 12
    "#{d.getHours()}:#{@pad(d.getMinutes())}#{(if meridian then ' a.m.' else '')}"

  is_midnight: (d) ->
    (d.getHours() is 0 and d.getMinutes() is 0)

  is_noon: (d) ->
    (d.getHours() is 12 and d.getMinutes() is 0)

  time_for: (item) ->
    if item['end_time']?
      if @is_midnight(item['start_time']) and @is_midnight(item['end_time']) and (item['start_time'].getDay() is item['end_time'].getDay() or item['start_time'].getDay() + 1 is item['end_time'].getDay()) 
        'All Day'
      else if item['start_time'].getDay() is item['end_time'].getDay()
        if item['start_time'].getHours() < 12 and item['end_time'].getHours() > 12
          "#{@format_time(item['start_time'])} &ndash; #{@format_time(item['end_time'])}"
        else
          "#{@format_time(item['start_time'], false)}&ndash;#{@format_time(item['end_time'])}"
      else
        "#{@format_time(item['start_time'])} &ndash; #{@format_time(item['end_time'])}"
    else
      return 'All Day' if @is_midnight(item['start_time'])
      @format_time(item['start_time'])

  location_for: (item) ->
    item['location']

  has_summary: (item) ->
    summary = @summary_for(item)
    (summary? and summary.length? and summary.length > 0)

  summary_for: (item) ->
    summary = item['summary'].replace(/(<([^>]+)>)/ig, ' ').replace('&#160;', ' ').replace(/^\s+|\s+$/, '').replace(/\s+/, ' ')
    return "#{summary.substr(0, summary.lastIndexOf(' ', 290))} &hellip;" if summary.length > 290
    summary

  render: (position, data) ->
    key = data['key'].replace(/:/, '_')
    item = data['item']
    screenWidth = $(window).width()
    screenHeight = $(window).height()
    output = '
    <article id="' + key + '" style="opacity: 0;left:' + (screenWidth * (position+1) + 18) + 'px;width: ' + (screenWidth-36) + 'px;height: ' + (screenHeight-36) + 'px;">
      ' + (if item['images']? and item['images'][0]? then '<img src="' + item['images'][0].url + '" alt="' + item['images'][0].alt + '" />' else '') + '
      <div>
        <h2 class="when' + @day_css(item['start_time']) + '">
          <span class="day">' + @day_for(item['start_time']) + '</span>
          <span class="time">' + @time_for(item) + '</span>
        </h2>
        <h3 class="what">
          <span class="title">' + item['title'].toTitleCaps() + '</span>
        </h3>
        ' + (if @location_for(item)? then '<h4 class="where"><span class="location">' + @location_for(item) + '</span></h4>' else '') + '
        <p class="extra-details">
          ' + (if item['repeat']? and item['repeat']['next_start_time']? then '<span class="repeats_next">' + item['repeat']['next_start_time'] + '</span>' else '') + '
        </p>
        ' + (if @has_summary(item) then '<div class="about"><p>' + @summary_for(item) + '</p></div>' else '') + '
        <h4 class="contact">
          <span class="school">' + item['group']['school'] + '</span>
          <span class="group">' + item['group']['name'] + '</span>
          ' + '<span class="link">' + (if item['qrcode']? then item['qrcode'].replace(/\.qrcode$/, '') else item['link']).replace(/^http(s?):\/\/(www)?\./i, '').replace(/\/(\d+)-?[a-z\-]+$/i, '/$1') + (if item['qrcode']? then '<img src="' + (if item['qrcode'].match(/\.qrcode$/) then item['qrcode'] else "#{item['qrcode']}.qrcode") + '" alt="QR Code" />' else '') + '</span>
        </h4>
      </div>
    </article>'
    $("#announcements").append(output)
    $("#" + key).animate({
      opacity: 1
    }, 1000).prev().animate({
      opacity: 0
    }, 500)
    $("#announcements").animate({
      left: '-=' + screenWidth
    }, 1500, 'easeInOutBack')
