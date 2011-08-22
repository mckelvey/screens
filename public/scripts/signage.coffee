
$(document).ready ->

  $("#guide").fadeIn(750)

  socket = io.connect window.location
  views = new Views()
  controller = new Controller(socket, views)
  document.signage =
    views: views
    controller: controller

  socket.on 'channel',
    (data) ->
      document.signage.controller.set_channel(data['channel'])

  socket.on 'update',
    (data) ->
      console.log data
      document.signage.controller.update(data)

  socket.on 'remove',
    (data) ->
      alert "item received"
      document.signage.controller.remove(data['item'])

  socket.on 'empty',
    (data) ->
      console.log 'empty received'
      console.log data

  socket.on 'error',
    (data) ->
      console.log 'error received'
      console.log data

  socket.on 'reload',
    (data) ->
      window.location.reload()


class Controller

  constructor: (socket, views) ->
    @socket = socket
    @views = views
    @queue = []
    @buffer_size = 30
    @screen = ''
    @channel = ''
    @position = 0
    @interval = null
    @seconds = 5

  running: () ->
    return true if @interval?
    false

  set_channel: (channel) ->
    @channel = channel
    @buffer()
  
  has: (key) ->
    for queued, index in @queue
      return index if key is queued['key']
    null

  date: (value) ->
    new Date(Date.parse(value))

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
          console.log object.queue[index]['item']
          console.log data.data.url
          object.queue[index]['item']['qrcode'] = data.data.url if index?
      error: (jqXHR, textStatus, errorThrown) ->
        null
    })

  is_live: (item) ->
    return true if item['status'] is 1
    false

  update: (data) ->
    #try
      data['item'] = JSON.parse data['item']
      data['item'] = @datify(data['item'])
      exists = @has(data['key'])
      console.log data
      if exists?
        @queue[exists] = data
      else
        @queue.push data if @is_live(data['item']) # insert by time; do filtering here, drop if over 30
      @qrcodify(data['key'], data['item']['link'])
      @begin() if !@running()
    #catch e
      #console.log e

  remove: (key) ->
    index = @has(key)
    if index?
      @queue.splice index, 1
      @position -= 1 if @position >= index
      @buffer()

  buffer: () ->
    return if @queue.length >= @buffer_size
    @socket.emit 'items', { count: (@buffer_size - @queue.length) }

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

  reset: () ->
    # show help, clear behind, reset section
    $("#guide").fadeIn(750)
    $("#announcements").html('').css('left', 0)
    @position = -1
    # @end()
    # @render()

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
    ((d.getTime() - now.getTime()) < 604800000)

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
    return "#{(d.getHours() - 12)}:#{@pad(d.getMinutes())}#{(' p.m.' if meridian)}" if d.getHours() > 12
    "#{d.getHours()}:#{@pad(d.getMinutes())}#{(' a.m.' if meridian)}"

  time_for: (item) ->
    if item['end_time']?
      if item['start_time'].getDay() is item['end_time'].getDay()
        if item['start_time'].getHours() < 12 and item['end_time'].getHours() > 12
          "#{@format_time(item['start_time'])} &ndash; #{@format_time(item['end_time'])}"
        else
          "#{@format_time(item['start_time'], false)}&ndash;#{@format_time(item['end_time'])}"
      else
        "#{@format_time(item['start_time'])} &ndash; #{@format_time(item['end_time'])}"
    else
      return 'All Day' if item['start_time'].getHours() is 0 and item['start_time'].getMinutes() is 0
      @format_time(item['start_time'])

  render: (position, data) ->
    console.log "count: #{position}"
    key = data['key'].replace(/:/, '_')
    item = data['item']
    output = '
    <article id="' + key + '" style="opacity: 0;left:' + (@screenWidth * (position+1) + 18) + 'px;width: ' + (@screenWidth-36) + 'px;height: ' + (@screenHeight-36) + 'px;">
      ' + (if item['images']? and item['images'][0]? then '<img src="' + item['images'][0].url + '" alt="' + item['images'][0].alt + '" />' else '') + '
      <div>
        <h2 class="when' + @day_css(item['start_time']) + '">
          <span class="day">' + @day_for(item['start_time']) + '</span>
          <span class="time">' + @time_for(item) + '</span>
        </h2>
        <h3 class="what">
          <span class="title">' + item['title'] + '</span>
        </h3>
        <h4 class="where">
          <span class="location">' + item['location'] + '</span>
        </h4>
        <p class="extra-details">
          ' + (if item['repeat']? and item['repeat']['next_start_time']? then '<span class="repeats_next">' + item['repeat']['next_start_time'] + '</span>' else '') + '
        </p>
        ' + (if item['summary']? and item['summary'].length > 0 then '<div class="about"><p>' + item['summary'].replace(/(<([^>]+)>)/ig, ' ') + '</p></div>' else '') + '
        <h4 class="contact">
          <span class="school">' + item['group']['school'] + '</span>
          <span class="group">' + item['group']['name'] + '</span>
          ' + '<span class="link">' + (if item['qrcode']? then item['qrcode'] else item['link']).replace(/^http(s?):\/\/(www)?\./i, '').replace(/\/(\d+)-?[a-z\-]+$/i, '/$1') + (if item['qrcode']? then '<img src="' + item['qrcode'] + '.qrcode" alt="QR Code" />' else '') + '</span>
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
      left: '-=' + @screenWidth
    }, 1500, 'easeInOutBack')


###

TO DO - Short Term

1) insert 'update's into local queue by timestamp, or exclude if full

2) fix timeline push for college only (timeline:undefined)

3) select channel, add screen data to channel push

4) write listener to store impressions


TO DO - Long Term

1) filtering tests
  i) date change
  ii) authority relationship
  iii) live status change
  iv) parent filtering
  v) duplicate filtering

2) Push needs to handle image-only changes

3) Push needs to test if an update no longer matches the subscription, send is_removed

###