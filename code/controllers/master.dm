 /**
  * StonedMC
  *
  * Designed to properly split up a given tick among subsystems
  * Note: if you read parts of this code and think "why is it doing it that way"
  * Odds are, there is a reason
  *
 **/

//This is the ABSOLUTE ONLY THING that should init globally like this
//2019 update: the failsafe,config and Global controllers also do it
GLOBAL_REAL(Master, /datum/controller/master) = new

//THIS IS THE INIT ORDER
//Master -> SSPreInit -> GLOB -> world -> config -> SSInit -> Failsafe
//GOT IT MEMORIZED?

/datum/controller/master
	name = "Master"

	/// Are we processing (higher values increase the processing delay by n ticks)
	var/processing = TRUE
	/// How many times have we ran
	var/iteration = 0

	/// Stack end detector to detect stack overflows that kill the mc's main loop
	var/datum/stack_end_detector/stack_end_detector

	/// world.time of last fire, for tracking lag outside of the mc
	var/last_run

	/// List of subsystems to process().
	var/list/subsystems

	/// Vars for keeping track of tick drift.
	var/init_timeofday
	var/init_time
	var/tickdrift = 0

	/// How long is the MC sleeping between runs, read only (set by Loop() based off of anti-tick-contention heuristics)
	var/sleep_delta = 1

	/// Only run ticker subsystems for the next n ticks.
	var/skip_ticks = 0

	/// makes the mc main loop runtime
	var/make_runtime = FALSE

	var/initializations_finished_with_no_players_logged_in	//I wonder what this could be?

	/// The type of the last subsystem to be fire()'d.
	var/last_type_processed

	var/datum/controller/subsystem/queue_head //!Start of queue linked list
	var/datum/controller/subsystem/queue_tail //!End of queue linked list (used for appending to the list)
	var/queue_priority_count = 0 //Running total so that we don't have to loop thru the queue each run to split up the tick
	var/queue_priority_count_bg = 0 //Same, but for background subsystems
	var/map_loading = FALSE	//!Are we loading in a new map?

	var/current_runlevel	//!for scheduling different subsystems for different stages of the round
	var/sleep_offline_after_initializations = TRUE

	var/static/restart_clear = 0
	var/static/restart_timeout = 0
	var/static/restart_count = 0

	var/static/random_seed

	/// During initialization, will be the instanced subsystem that is currently initializing.
	/// Outside of initialization, returns null.
	var/current_initializing_subsystem = null

	///current tick limit, assigned before running a subsystem.
	///used by CHECK_TICK as well so that the procs subsystems call can obey that SS's tick limits
	var/static/current_ticklimit = TICK_LIMIT_RUNNING

/datum/controller/master/New()
	if(!config)
		config = new
	// Highlander-style: there can only be one! Kill off the old and replace it with the new.

	if(!random_seed)
		random_seed = (TEST_RUN_PARAMETER in world.params) ? 29051994 : rand(1, 1e9)
		rand_seed(random_seed)

	var/list/_subsystems = list()
	subsystems = _subsystems
	if (Master != src)
		if (istype(Master)) //If there is an existing MC take over his stuff and delete it
			Recover()
			qdel(Master)
			Master = src
		else
			//Code used for first master on game boot or if existing master got deleted
			Master = src
			var/list/subsystem_types = subtypesof(/datum/controller/subsystem)
			sortTim(subsystem_types, /proc/cmp_subsystem_init)
			//Find any abandoned subsystem from the previous master (if there was any)
			var/list/existing_subsystems = list()
			for(var/global_var in global.vars)
				if (istype(global.vars[global_var], /datum/controller/subsystem))
					existing_subsystems += global.vars[global_var]
			//Either init a new SS or if an existing one was found use that
			for(var/I in subsystem_types)
				var/ss_idx = existing_subsystems.Find(I)
				if (ss_idx)
					_subsystems += existing_subsystems[ss_idx]
				else
					_subsystems += new I

	if(!GLOB)
		new /datum/controller/global_vars

/datum/controller/master/Destroy()
	..()
	// Tell qdel() to Del() this object.
	return QDEL_HINT_HARDDEL_NOW

/datum/controller/master/Shutdown()
	processing = FALSE
	sortTim(subsystems, /proc/cmp_subsystem_init)
	reverseRange(subsystems)
	for(var/datum/controller/subsystem/ss in subsystems)
		log_world("Shutting down [ss.name] subsystem...")
		ss.Shutdown()
	log_world("Shutdown complete")

// Returns 1 if we created a new mc, 0 if we couldn't due to a recent restart,
//	-1 if we encountered a runtime trying to recreate it
/proc/Recreate_MC()
	. = -1 //so if we runtime, things know we failed
	if (world.time < Master.restart_timeout)
		return 0
	if (world.time < Master.restart_clear)
		Master.restart_count *= 0.5

	var/delay = 50 * ++Master.restart_count
	Master.restart_timeout = world.time + delay
	Master.restart_clear = world.time + (delay * 2)
	if (Master) //Can only do this if master hasn't been deleted
		Master.processing = FALSE //stop ticking this one
	try
		new/datum/controller/master()
	catch
		return -1
	return 1


/datum/controller/master/Recover()
	var/msg = "## DEBUG: [time2text(world.timeofday)] MC restarted. Reports:\n"
	for (var/varname in Master.vars)
		switch (varname)
			if("name", "tag", "bestF", "type", "parent_type", "vars", "statclick") // Built-in junk.
				continue
			else
				var/varval = Master.vars[varname]
				if (istype(varval, /datum)) // Check if it has a type var.
					var/datum/D = varval
					msg += "\t [varname] = [D]([D.type])\n"
				else
					msg += "\t [varname] = [varval]\n"
	log_world(msg)

	var/datum/controller/subsystem/BadBoy = Master.last_type_processed
	var/FireHim = FALSE
	if(istype(BadBoy))
		msg = null
		LAZYINITLIST(BadBoy.failure_strikes)
		switch(++BadBoy.failure_strikes[BadBoy.type])
			if(2)
				msg = "The [BadBoy.name] subsystem was the last to fire for 2 controller restarts. It will be recovered now and disabled if it happens again."
				FireHim = TRUE
			if(3)
				msg = "The [BadBoy.name] subsystem seems to be destabilizing the MC and will be offlined."
				BadBoy.flags |= SS_NO_FIRE
		if(msg)
			to_chat(GLOB.admins, span_boldannounce("[msg]"))
			log_world(msg)

	if (istype(Master.subsystems))
		if(FireHim)
			Master.subsystems += new BadBoy.type	//NEW_SS_GLOBAL will remove the old one
		subsystems = Master.subsystems
		current_runlevel = Master.current_runlevel
		StartProcessing(10)
	else
		to_chat(world, span_boldannounce("The Master Controller is having some issues, we will need to re-initialize EVERYTHING"))
		Initialize(20, TRUE)


// Please don't stuff random bullshit here,
// 	Make a subsystem, give it the SS_NO_FIRE flag, and do your work in it's Initialize()
/datum/controller/master/Initialize(delay, init_sss, tgs_prime)
	set waitfor = 0

	if(delay)
		sleep(delay)

	if(tgs_prime)
		world.TgsInitializationComplete()

	if(init_sss)
		init_subtypes(/datum/controller/subsystem, subsystems)

	to_chat(world, span_boldannounce("Initializing subsystems..."))

	// Sort subsystems by init_order, so they initialize in the correct order.
	sortTim(subsystems, /proc/cmp_subsystem_init)
	//yogs -- loading progress stuff; have to initialize this static
	for(var/s in subsystems)
		var/datum/controller/subsystem/SS = s
		SS.total_loading_points += SS.loading_points
	//yogs end

	var/start_timeofday = REALTIMEOFDAY
	// Initialize subsystems.
	current_ticklimit = CONFIG_GET(number/tick_limit_mc_init)
	for (var/datum/controller/subsystem/SS in subsystems)
		if (SS.flags & SS_NO_INIT || SS.initialized) //Don't init SSs with the correspondig flag or if they already are initialzized
			continue
		current_initializing_subsystem = SS
		SS.Initialize(REALTIMEOFDAY)
		CHECK_TICK
	current_initializing_subsystem = null
	current_ticklimit = TICK_LIMIT_RUNNING
	var/time = (REALTIMEOFDAY - start_timeofday) / 10

	var/msg = "Initializations complete within [time] second[time == 1 ? "" : "s"]!"
	to_chat(world, span_boldannounce("[msg]"))
	log_world(msg)
	//yogs start - webhook support
	var/list/webhookData = list(\
								"map_name" = SSmapping.config.map_name,             \
								"round" = GLOB.round_id,       \
								"revision" = GLOB.revdata.commit,      \
								"changelog_hash" = GLOB.changelog_hash)
	webhook_send_roundstatus("lobby", webhookData) //yogs end -webhook support

	if (!current_runlevel)
		SetRunLevel(1)

	// Sort subsystems by display setting for easy access.
	sortTim(subsystems, /proc/cmp_subsystem_display)
	// Set world options.
	world.change_fps(CONFIG_GET(number/fps))
	var/initialized_tod = REALTIMEOFDAY

	if(sleep_offline_after_initializations)
		world.sleep_offline = TRUE
	sleep(1)

	if(sleep_offline_after_initializations && CONFIG_GET(flag/resume_after_initializations))
		world.sleep_offline = FALSE
	initializations_finished_with_no_players_logged_in = initialized_tod < REALTIMEOFDAY - 10
	// Loop.
	Master.StartProcessing(0)

/datum/controller/master/proc/SetRunLevel(new_runlevel)
	var/old_runlevel = current_runlevel
	if(isnull(old_runlevel))
		old_runlevel = "NULL"

	testing("MC: Runlevel changed from [old_runlevel] to [new_runlevel]")
	current_runlevel = log(2, new_runlevel) + 1
	if(current_runlevel < 1)
		CRASH("Attempted to set invalid runlevel: [new_runlevel]")

// Starts the mc, and sticks around to restart it if the loop ever ends.
/datum/controller/master/proc/StartProcessing(delay)
	set waitfor = 0
	if(delay)
		sleep(delay)
	testing("Master starting processing")
	var/rtn = Loop()
	if (rtn > 0 || processing < 0)
		return //this was suppose to happen.
	//loop ended, restart the mc
	log_game("MC crashed or runtimed, restarting")
	message_admins("MC crashed or runtimed, restarting")
	var/rtn2 = Recreate_MC()
	if (rtn2 <= 0)
		log_game("Failed to recreate MC (Error code: [rtn2]), it's up to the failsafe now")
		message_admins("Failed to recreate MC (Error code: [rtn2]), it's up to the failsafe now")
		Failsafe.defcon = 2

// Main loop.
/datum/controller/master/proc/Loop()
	. = -1
	//Prep the loop (most of this is because we want MC restarts to reset as much state as we can, and because
	//	local vars rock

	//all this shit is here so that flag edits can be refreshed by restarting the MC. (and for speed)
	var/list/tickersubsystems = list()
	var/list/runlevel_sorted_subsystems = list(list())	//ensure we always have at least one runlevel
	var/timer = world.time
	for (var/thing in subsystems)
		var/datum/controller/subsystem/SS = thing
		if (SS.flags & SS_NO_FIRE)
			continue
		SS.queued_time = 0
		SS.queue_next = null
		SS.queue_prev = null
		SS.state = SS_IDLE
		if ((SS.flags & (SS_TICKER|SS_BACKGROUND)) == SS_TICKER)
			tickersubsystems += SS
			timer += world.tick_lag * rand(1, 5)
			SS.next_fire = timer
			continue

		var/ss_runlevels = SS.runlevels
		var/added_to_any = FALSE
		for(var/I in 1 to GLOB.bitflags.len)
			if(ss_runlevels & GLOB.bitflags[I])
				while(runlevel_sorted_subsystems.len < I)
					runlevel_sorted_subsystems += list(list())
				runlevel_sorted_subsystems[I] += SS
				added_to_any = TRUE
		if(!added_to_any)
			WARNING("[SS.name] subsystem is not SS_NO_FIRE but also does not have any runlevels set!")

	queue_head = null
	queue_tail = null
	//these sort by lower priorities first to reduce the number of loops needed to add subsequent SS's to the queue
	//(higher subsystems will be sooner in the queue, adding them later in the loop means we don't have to loop thru them next queue add)
	sortTim(tickersubsystems, /proc/cmp_subsystem_priority)
	for(var/I in runlevel_sorted_subsystems)
		sortTim(runlevel_sorted_subsystems, /proc/cmp_subsystem_priority)
		I += tickersubsystems

	var/cached_runlevel = current_runlevel
	var/list/current_runlevel_subsystems = runlevel_sorted_subsystems[cached_runlevel]

	init_timeofday = REALTIMEOFDAY
	init_time = world.time

	iteration = 1
	var/error_level = 0
	var/sleep_delta = 1
	var/list/subsystems_to_check
	//setup the stack overflow detector
	stack_end_detector = new()
	var/datum/stack_canary/canary = stack_end_detector.prime_canary()
	canary.use_variable()
	//the actual loop.

	while (1)
		tickdrift = max(0, MC_AVERAGE_FAST(tickdrift, (((REALTIMEOFDAY - init_timeofday) - (world.time - init_time)) / world.tick_lag)))
		var/starting_tick_usage = TICK_USAGE
		if (processing <= 0)
			current_ticklimit = TICK_LIMIT_RUNNING
			sleep(10)
			continue

		//Anti-tick-contention heuristics:
		//if there are mutiple sleeping procs running before us hogging the cpu, we have to run later.
		//	(because sleeps are processed in the order received, longer sleeps are more likely to run first)
		if (starting_tick_usage > TICK_LIMIT_MC) //if there isn't enough time to bother doing anything this tick, sleep a bit.
			sleep_delta *= 2
			current_ticklimit = TICK_LIMIT_RUNNING * 0.5
			sleep(world.tick_lag * (processing * sleep_delta))
			continue

		//Byond resumed us late. assume it might have to do the same next tick
		if (last_run + CEILING(world.tick_lag * (processing * sleep_delta), world.tick_lag) < world.time)
			sleep_delta += 1

		sleep_delta = MC_AVERAGE_FAST(sleep_delta, 1) //decay sleep_delta

		if (starting_tick_usage > (TICK_LIMIT_MC*0.75)) //we ran 3/4 of the way into the tick
			sleep_delta += 1

		//debug
		if (make_runtime)
			var/datum/controller/subsystem/SS
			SS.can_fire = 0

		if (!Failsafe || (Failsafe.processing_interval > 0 && (Failsafe.lasttick+(Failsafe.processing_interval*5)) < world.time))
			new/datum/controller/failsafe() // (re)Start the failsafe.

		//now do the actual stuff
		if (!skip_ticks)
			var/checking_runlevel = current_runlevel
			if(cached_runlevel != checking_runlevel)
				//resechedule subsystems
				cached_runlevel = checking_runlevel
				current_runlevel_subsystems = runlevel_sorted_subsystems[cached_runlevel]
				var/stagger = world.time
				for(var/I in current_runlevel_subsystems)
					var/datum/controller/subsystem/SS = I
					if(SS.next_fire <= world.time)
						stagger += world.tick_lag * rand(1, 5)
						SS.next_fire = stagger

			subsystems_to_check = current_runlevel_subsystems
		else
			subsystems_to_check = tickersubsystems

		if (CheckQueue(subsystems_to_check) <= 0) //error processing queue
			stack_trace("MC: CheckQueue failed. Current error_level is [round(error_level, 0.25)]")
			if (!SoftReset(tickersubsystems, runlevel_sorted_subsystems))
				error_level++
				CRASH("MC: SoftReset() failed, exiting loop()")

			if (error_level < 2) //except for the first strike, stop incrmenting our iteration so failsafe enters defcon
				iteration++
			else
				cached_runlevel = null //3 strikes, Lets reset the runlevel lists
			current_ticklimit = TICK_LIMIT_RUNNING
			sleep((1 SECONDS) * error_level)
			error_level++
			continue

		if (queue_head)
			if (RunQueue() <= 0) //error running queue
				stack_trace("MC: RunQueue failed. Current error_level is [round(error_level, 0.25)]")
				if (error_level > 1) //skip the first error,
					if (!SoftReset(tickersubsystems, runlevel_sorted_subsystems))
						error_level++
						CRASH("MC: SoftReset() failed, exiting loop()")

					if (error_level <= 2) //after 3 strikes stop incrmenting our iteration so failsafe enters defcon
						iteration++
					else
						cached_runlevel = null //3 strikes, Lets also reset the runlevel lists
					current_ticklimit = TICK_LIMIT_RUNNING
					sleep((1 SECONDS) * error_level)
					error_level++
					continue
				error_level++
		if (error_level > 0)
			error_level = max(MC_AVERAGE_SLOW(error_level-1, error_level), 0)
		if (!queue_head) //reset the counts if the queue is empty, in the off chance they get out of sync
			queue_priority_count = 0
			queue_priority_count_bg = 0

		iteration++
		last_run = world.time
		if (skip_ticks)
			skip_ticks--
		src.sleep_delta = MC_AVERAGE_FAST(src.sleep_delta, sleep_delta)
		current_ticklimit = TICK_LIMIT_RUNNING
		if (processing * sleep_delta <= world.tick_lag)
			current_ticklimit -= (TICK_LIMIT_RUNNING * 0.25) //reserve the tail 1/4 of the next tick for the mc if we plan on running next tick
		sleep(world.tick_lag * (processing * sleep_delta))




// This is what decides if something should run.
/datum/controller/master/proc/CheckQueue(list/subsystemstocheck)
	. = 0 //so the mc knows if we runtimed

	//we create our variables outside of the loops to save on overhead
	var/datum/controller/subsystem/SS
	var/SS_flags

	for (var/thing in subsystemstocheck)
		if (!thing)
			subsystemstocheck -= thing
		SS = thing
		if (SS.state != SS_IDLE)
			continue
		if (SS.can_fire <= 0)
			continue
		if (SS.next_fire > world.time)
			continue
		SS_flags = SS.flags
		if (SS_flags & SS_NO_FIRE)
			subsystemstocheck -= SS
			continue
		if ((SS_flags & (SS_TICKER|SS_KEEP_TIMING)) == SS_KEEP_TIMING && SS.last_fire + (SS.wait * 0.75) > world.time)
			continue
		if (SS.postponed_fires >= 1)
			SS.postponed_fires--
			SS.update_nextfire()
			continue
		SS.enqueue()
	. = 1


/// RunQueue - Run thru the queue of subsystems to run, running them while balancing out their allocated tick precentage
/// Returns 0 if runtimed, a negitive number for logic errors, and a positive number if the operation completed without errors
/// RunQueue - Run thru the queue of subsystems to run, running them while balancing out their allocated tick precentage
/// Returns 0 if runtimed, a negitive number for logic errors, and a positive number if the operation completed without errors
/datum/controller/master/proc/RunQueue()
	. = 0
	var/datum/controller/subsystem/queue_node
	var/queue_node_flags
	var/queue_node_priority
	var/queue_node_paused
	var/current_tick_budget
	var/tick_precentage
	var/tick_remaining
	var/ran = TRUE //this is right
	var/bg_calc //have we swtiched current_tick_budget to background mode yet?
	var/tick_usage
	//keep running while we have stuff to run and we haven't gone over a tick
	// this is so subsystems paused eariler can use tick time that later subsystems never used
	while (ran && queue_head && TICK_USAGE < TICK_LIMIT_MC)
		ran = FALSE
		bg_calc = FALSE
		current_tick_budget = queue_priority_count
		queue_node = queue_head
		while (queue_node)
			if (ran && TICK_USAGE > TICK_LIMIT_RUNNING)
				break
			queue_node_flags = queue_node.flags
			queue_node_priority = queue_node.queued_priority
			if (!(queue_node_flags & SS_TICKER) && skip_ticks)
				queue_node = queue_node.queue_next
				continue

			if ((queue_node_flags & SS_BACKGROUND))
				if (!bg_calc)
					current_tick_budget = queue_priority_count_bg
					bg_calc = TRUE
			else if (bg_calc)
				//error state, do sane fallback behavior
				if (. == 0)
					log_world("MC: Queue logic failure, non-background subsystem queued to run after a background subsystem: [queue_node] queue_prev:[queue_node.queue_prev]")
				. = -1
				current_tick_budget = queue_priority_count //this won't even be right, but is the best we have.
				bg_calc = FALSE


			tick_remaining = TICK_LIMIT_RUNNING - TICK_USAGE

			if (queue_node_priority >= 0 && current_tick_budget > 0 && current_tick_budget >= queue_node_priority)
				//Give the subsystem a precentage of the remaining tick based on the remaining priority
				tick_precentage = tick_remaining * (queue_node_priority / current_tick_budget)
			else
				//error state
				if (. == 0)
					log_world("MC: tick_budget sync error. [json_encode(list(current_tick_budget, queue_priority_count, queue_priority_count_bg, bg_calc, queue_node, queue_node_priority))]")
				. = -1
				tick_precentage = tick_remaining //just because we lost track of priority calculations doesn't mean we can't try to finish off the run, if the error state persists, we don't want to stop ticks from happening

			tick_precentage = max(tick_precentage*0.5, tick_precentage-queue_node.tick_overrun)

			current_ticklimit = round(TICK_USAGE + tick_precentage)
			ran = TRUE
			queue_node_paused = (queue_node.state == SS_PAUSED || queue_node.state == SS_PAUSING)
			last_type_processed = queue_node
			queue_node.state = SS_RUNNING
			tick_usage = TICK_USAGE
			var/state = queue_node.ignite(queue_node_paused)
			tick_usage = TICK_USAGE - tick_usage
			if (state == SS_RUNNING)
				state = SS_IDLE
			current_tick_budget -= queue_node_priority
			if (tick_usage < 0)
				tick_usage = 0
			queue_node.tick_overrun = max(0, MC_AVG_FAST_UP_SLOW_DOWN(queue_node.tick_overrun, tick_usage-tick_precentage))
			queue_node.state = state
			if (state == SS_PAUSED)
				queue_node.paused_ticks++
				queue_node.paused_tick_usage += tick_usage
				queue_node = queue_node.queue_next
				continue
			queue_node.ticks = MC_AVERAGE(queue_node.ticks, queue_node.paused_ticks)
			tick_usage += queue_node.paused_tick_usage
			queue_node.tick_usage = MC_AVERAGE_FAST(queue_node.tick_usage, tick_usage)
			queue_node.cost = MC_AVERAGE_FAST(queue_node.cost, TICK_DELTA_TO_MS(tick_usage))
			queue_node.paused_ticks = 0
			queue_node.paused_tick_usage = 0
			if (bg_calc) //update our running total
				queue_priority_count_bg -= queue_node_priority
			else
				queue_priority_count -= queue_node_priority
			queue_node.last_fire = world.time
			queue_node.times_fired++
			queue_node.update_nextfire()
			queue_node.queued_time = 0
			//remove from queue
			queue_node.dequeue()

			queue_node = queue_node.queue_next

	if (. == 0)
		. = 1

//resets the queue, and all subsystems, while filtering out the subsystem lists
//	called if any mc's queue procs runtime or exit improperly.
/datum/controller/master/proc/SoftReset(list/ticker_SS, list/runlevel_SS)
	. = 0
	stack_trace("MC: SoftReset called, resetting MC queue state.")
	if (!istype(subsystems) || !istype(ticker_SS) || !istype(runlevel_SS))
		log_world("MC: SoftReset: Bad list contents: '[subsystems]' '[ticker_SS]' '[runlevel_SS]'")
		return
	var/subsystemstocheck = subsystems | ticker_SS
	for(var/I in runlevel_SS)
		subsystemstocheck |= I

	for (var/thing in subsystemstocheck)
		var/datum/controller/subsystem/SS = thing
		if (!SS || !istype(SS))
			//list(SS) is so if a list makes it in the subsystem list, we remove the list, not the contents
			subsystems -= list(SS)
			ticker_SS -= list(SS)
			for(var/I in runlevel_SS)
				I -= list(SS)
			log_world("MC: SoftReset: Found bad entry in subsystem list, '[SS]'")
			continue
		if (SS.queue_next && !istype(SS.queue_next))
			log_world("MC: SoftReset: Found bad data in subsystem queue, queue_next = '[SS.queue_next]'")
		SS.queue_next = null
		if (SS.queue_prev && !istype(SS.queue_prev))
			log_world("MC: SoftReset: Found bad data in subsystem queue, queue_prev = '[SS.queue_prev]'")
		SS.queue_prev = null
		SS.queued_priority = 0
		SS.queued_time = 0
		SS.state = SS_IDLE
	if (queue_head && !istype(queue_head))
		log_world("MC: SoftReset: Found bad data in subsystem queue, queue_head = '[queue_head]'")
	queue_head = null
	if (queue_tail && !istype(queue_tail))
		log_world("MC: SoftReset: Found bad data in subsystem queue, queue_tail = '[queue_tail]'")
	queue_tail = null
	queue_priority_count = 0
	queue_priority_count_bg = 0
	log_world("MC: SoftReset: Finished.")
	. = 1

/datum/controller/master/proc/laggy_byond_map_update_incoming()
	if (!skip_ticks)
		skip_ticks = 1

/datum/controller/master/stat_entry(msg)
	msg = "(TickRate:[Master.processing]) (Iteration:[Master.iteration]) (TickLimit: [round(Master.current_ticklimit, 0.1)])"
	return msg

/datum/controller/master/StartLoadingMap()
	//disallow more than one map to load at once, multithreading it will just cause race conditions
	while(map_loading)
		stoplag()
	for(var/S in subsystems)
		var/datum/controller/subsystem/SS = S
		SS.StartLoadingMap()
	map_loading = TRUE

/datum/controller/master/StopLoadingMap(bounds = null)
	map_loading = FALSE
	for(var/S in subsystems)
		var/datum/controller/subsystem/SS = S
		SS.StopLoadingMap()


/datum/controller/master/proc/UpdateTickRate()
	if (!processing)
		return
	var/client_count = length(GLOB.clients)
	if (client_count < CONFIG_GET(number/mc_tick_rate/disable_high_pop_mc_mode_amount))
		processing = CONFIG_GET(number/mc_tick_rate/base_mc_tick_rate)
	else if (client_count > CONFIG_GET(number/mc_tick_rate/high_pop_mc_mode_amount))
		processing = CONFIG_GET(number/mc_tick_rate/high_pop_mc_tick_rate)

/datum/controller/master/proc/OnConfigLoad()
	for (var/thing in subsystems)
		var/datum/controller/subsystem/SS = thing
		SS.OnConfigLoad()
