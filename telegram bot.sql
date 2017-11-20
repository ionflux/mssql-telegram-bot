set nocount on

declare
	@telegram_api_host nvarchar(200) = 'https://api.telegram.org/bot',
	@bot_token nvarchar(200) = '-------:---------------',
	@update_timeout int = 50

declare
	@http_headers xml = '<Header Name="Content-Type" Value="application/json" />';

declare
	@need_stop bit = 0,
	@url nvarchar(max),
	@me_url nvarchar(max),
	@query_url nvarchar(max),
	@message_url nvarchar(max),
	@success bit,
    @response nvarchar(max),
    @error nvarchar(max),
	@chat_message nvarchar(max)

set @url = concat(@telegram_api_host, @bot_token, '/')

set @me_url = concat(@url, 'getMe')
set @query_url = concat(@url, 'getUpdates')
set @message_url = concat(@url, 'sendMessage')

exec dbo.sp_HttpPost
	@url = @me_url,
	@headerXml = @http_headers,
	@requestBody = '',
	@success = @success output,
	@response = @response output,
	@error = @error output

print @response

if @success = 1
begin
	declare
		@bot_id bigint,
		@bot_name nvarchar(max),
		@bot_username nvarchar(max)

	select
		@bot_id = bot_id,
		@bot_name = first_name,
		@bot_username = username
	from
		openjson(@response, '$.result') with (
			bot_id bigint '$.id',
			first_name nvarchar(max) '$.first_name',
			username nvarchar(max) '$.username'
		)

	declare @updates table (
		update_id bigint primary key,
		message_id bigint,
		message_date int,
		message_text nvarchar(max),
		message_from_is_bot bit,
		message_chat_id bigint
	)

	declare @new_updates table (update_id bigint primary key)

	declare
		@json_update nvarchar(max) = '{}',
		@offset int = 0

	while @need_stop = 0
	begin
		delete from @new_updates

		select @offset = isnull(max(update_id) + 1, 0) from @updates

		set @json_update = json_modify(@json_update,'$.timeout', @update_timeout)
		set @json_update = json_modify(@json_update,'$.offset', @offset)

		exec dbo.sp_HttpPost
			@url = @query_url,
			@headerXml = @http_headers,
			@requestBody = @json_update,
			@success = @success output,
			@response = @response output,
			@error = @error output

		if @success = 1
		begin
			insert into @updates
			output Inserted.update_id into @new_updates
			select
				update_id,
				message_id,
				message_date,
				message_text,
				message_from_is_bot,
				message_chat_id
			from
				openjson(@response, '$.result') with (
					update_id bigint '$.update_id',
					message_id nvarchar(max) '$.message.message_id',
					message_date int '$.message.date',
					message_text nvarchar(max) '$.message.text',

					message_from_is_bot bit '$.message.from.is_bot',
					message_from_first_name nvarchar(max) '$.message.from.first_name',
					message_from_last_name nvarchar(max) '$.message.from.last_name',
					message_from_username nvarchar(max) '$.message.from.username',
					message_from_language_code nvarchar(max) '$.message.from.language_code',

					message_chat_id bigint '$.message.chat.id',
					message_chat_type nvarchar(100) '$.message.chat.type',
					message_chat_title nvarchar(max) '$.message.chat.title',
					message_chat_all_members_are_administrators bit '$.message.chat.all_members_are_administrators',
					message_chat_first_name nvarchar(100) '$.message.chat.first_name',
					message_chat_last_name nvarchar(100) '$.message.chat.last_name',
					message_chat_username nvarchar(100) '$.message.chat.username'
				)
		end

		if (@offset = 0)
		begin
			raiserror ('first run', 0, 1) with nowait

			declare 
				@json_chat nvarchar(max) = '{"text": "Bot started"}',
				@message_chat_id bigint

			declare start_cur cursor local for select distinct message_chat_id from @updates
			open start_cur

			fetch next from start_cur into @message_chat_id

			while @@FETCH_STATUS = 0
			begin
				set @json_chat = json_modify(@json_chat, '$.chat_id', @message_chat_id)

				print concat('@message_chat_id = ', @message_chat_id)

				exec dbo.sp_HttpPost
					@url = @message_url,
					@headerXml = @http_headers,
					@requestBody = @json_chat,
					@success = @success output,
					@response = @response output,
					@error = @error output

				fetch next from start_cur into @message_chat_id
			end

			close start_cur
			deallocate start_cur
		end

		if (@offset > 0) and ((select count(*) from @new_updates) > 0)
		begin
			declare
				@message_id bigint,
				@message_text nvarchar(max)

			declare cur_cmd cursor local for select up.message_id, up.message_text, up.message_chat_id from @updates up inner join @new_updates new on new.update_id = up.update_id where message_from_is_bot = 0
			open cur_cmd

			fetch next from cur_cmd into @message_id, @message_text, @message_chat_id

			while @@FETCH_STATUS = 0
			begin
				set @chat_message = ''

				if charindex('@', @message_text) > 0
				begin
					declare @find_name nvarchar(max)
					select @find_name = value from string_split(@message_text, '@')

					if @find_name = @bot_username
						select top 1 @message_text = value from string_split(@message_text, '@')
					else
						set @message_text = ''
				end

				set @error = concat('message cmd: ', @message_text)
				raiserror (@error, 0, 1) with nowait

				if @message_text = 'stop' or @message_text = '/stop'
				begin
					set @need_stop = 1
					set @chat_message = 'Receive stop command'
				end

				if @message_text = 'status' or @message_text = '/status'
				begin
					set @chat_message = 'Unknown recalc status'
				end

				if @chat_message != ''
				begin
					set @json_chat = json_modify(@json_chat, '$.text', @chat_message)
					set @json_chat = json_modify(@json_chat, '$.chat_id', @message_chat_id)

					exec dbo.sp_HttpPost
						@url = @message_url,
						@headerXml = @http_headers,
						@requestBody = @json_chat,
						@success = @success output,
						@response = @response output,
						@error = @error output
				end

				fetch next from cur_cmd into @message_id, @message_text, @message_chat_id
			end

			close cur_cmd
			deallocate cur_cmd
		end

		set @error = concat('repeat, id: ', @offset)
		raiserror (@error,  0, 1) with nowait
	end
end

/*

set nocount on 

declare 
	@position int = 1, 
	@nstring nvarchar(max),
	@outstr nvarchar(max) = ''

set @nstring = N'хуйца сосни';  

while @position <= len(@nstring)  
begin
	select @outstr = @outstr + '\u' + sys.fn_varbintohexsubstring(0, convert(binary(2), unicode(substring(@nstring, @position, 1))), 1, 0)
	set @position = @position + 1;
end;  

print @outstr

set @json = '{"text":"\u0445\u0443\u0439\u0446\u0430\u0020\u0441\u043e\u0441\u043d\u0438"}'

print unicode('Проверка')

SET @json=json_modify(@json,'$.chat_id','-265426426')
-- SET @json=json_modify(@json,'$.text','\u0445\u0443\u0439\u0446\u0430\u0020\u0441\u043e\u0441\u043d\u0438')

print @json

 -- N'{"chat_id": "60568061", "text":""}',

exec dbo.sp_HttpPost @url = N'https://api.telegram.org/bot215656793:AAFSzw_WF4fCy8dCAC329z30AvFC3w1ZTTE/sendMessage',                   -- nvarchar(max)
                    @headerXml = @http_headers,            -- xml
					@requestBody = @json,
                    @success = @success output,   -- bit
                    @response = @response output, -- nvarchar(max)
                    @error = @error output        -- nvarchar(max)

print @success
print @response
*/