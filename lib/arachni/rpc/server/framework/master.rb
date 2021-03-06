=begin
    Copyright 2010-2014 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

module Arachni
class RPC::Server::Framework

#
# Holds methods for master Instances, both for remote management and utility ones.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
module Master

    #
    # Sets this instance as the master.
    #
    # @return   [Bool]
    #   `true` on success, `false` if this instance is not a {#solo? solo} one.
    #
    def set_as_master
        return false if !solo?
        return true if master?

        # Holds info for our slave Instances -- if we have any.
        @instances        = []

        # Instances which have been distributed some scan workload.
        @running_slaves   = Set.new

        # Instances which have completed their scan.
        @done_slaves      = Set.new

        # Holds element IDs for each page, to be used as a representation of the
        # the audit workload that will need to be distributed.
        @element_ids_per_url = {}

        # Some methods need to be accessible over RPC for instance management,
        # restricting elements, adding more pages etc.
        #
        # However, when in multi-Instance mode, the master should not be tampered
        # with, so we generate a local token (which is not known to regular API clients)
        # to be used server side by self to facilitate access control and only
        # allow slaves to update our runtime data.
        @local_token = Utilities.generate_token

        print_status 'Became master.'

        true
    end

    # @return   [Bool]
    #   `true` if running in HPG (High Performance Grid) mode and instance is
    #   the master, false otherwise.
    def master?
        # Only master needs a local token.
        !!@local_token
    end

    #
    # Enslaves another instance and subsequently becomes the master of the group.
    #
    # @param    [Hash]  instance_info
    #   `{ 'url' => '<host>:<port>', 'token' => 's3cr3t' }`
    #
    # @return   [Bool]
    #   `true` on success, `false` is this instance is a slave (slaves can't
    #   have slaves of their own).
    #
    def enslave( instance_info, opts = {}, &block )
        # Slaves can't have slaves of their own.
        if slave?
            block.call false
            return false
        end

        instance_info = instance_info.symbolize_keys

        fail "Instance info does not contain a 'url' key."   if !instance_info[:url]
        fail "Instance info does not contain a 'token' key." if !instance_info[:token]

        # Since we have slaves we must be a master.
        set_as_master

        # Take charge of the Instance we were given.
        instance = connect_to_instance( instance_info )
        instance.opts.set( cleaned_up_opts ) do
            instance.framework.set_master( multi_self_url, token ) do
                @instances << instance_info

                print_status "Enslaved: #{instance_info[:url]}"

                block.call true if block_given?
            end
        end

        true
    end

    #
    # Signals that a slave has finished auditing -- each slave must call this
    # when it finishes its job.
    #
    # @param    [String]    slave_url   URL of the calling slave.
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  `true` on success, `false` on invalid `token`.
    #
    # @private
    #
    def slave_done( slave_url, token = nil )
        return false if master? && !valid_token?( token )
        @done_slaves << slave_url

        print_status "Slave done: #{slave_url}"

        cleanup_if_all_done
        true
    end

    #
    # Registers an array holding {Arachni::Issue} objects with the local instance.
    #
    # Used by slaves to register the issues they find.
    #
    # @param    [Array<Arachni::Issue>]    issues
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  `true` on success, `false` on invalid `token`.
    #
    # @private
    #
    def update_issues( issues, token = nil )
        return false if master? && !valid_token?( token )
        @modules.class.register_results( issues )
        true
    end

    #
    # Used by slave crawlers to update the master's list of element IDs per URL.
    #
    # @param    [Hash]     element_ids_per_url
    #   List of element IDs (as created by
    #   {Arachni::Element::Capabilities::Auditable#scope_audit_id}) for each
    #   page (by URL).
    #
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  `true` on success, `false` on invalid `token`.
    #
    # @private
    #
    def update_element_ids_per_url( element_ids_per_url = {}, token = nil )
        return false if master? && !valid_token?( token )

        element_ids_per_url.each do |url, ids|
            @element_ids_per_url[url] ||= []
            @element_ids_per_url[url] |= ids
        end

        true
    end

    #
    # Used by slaves to impart the knowledge they've gained during the scan to
    # the master as well as for signaling.
    #
    # @param    [Hash]     data
    # @option data [Boolean] :crawl_done
    #   `true` if the peer has finished crawling, `false` otherwise.
    # @option data [Boolean] :audit_done
    #   `true` if the slave has finished auditing, `false` otherwise.
    # @option data [Hash] :element_ids_per_url
    #   List of element IDs (as created by
    #   {Arachni::Element::Capabilities::Auditable#scope_audit_id}) for each
    #   page (by URL).
    # @option data [Hash] :platforms
    #   List of platforms (as created by {Platform::Manager.light}).
    # @option data [Array<Arachni::Issue>]    issues
    #
    # @param    [String]    url
    #   URL of the slave.
    # @param    [String]    token
    #   Privileged token, prevents this method from being called by 3rd parties
    #   when this instance is a master. If this instance is not a master one
    #   the token needn't be provided.
    #
    # @return   [Bool]  `true` on success, `false` on invalid `token`.
    #
    # @private
    #
    def slave_sitrep( data, url, token = nil )
        return false if master? && !valid_token?( token )

        update_element_ids_per_url( data[:element_ids_per_url] || {}, token )
        update_issues( data[:issues] || [], token )

        Platform::Manager.update_light( data[:platforms] || {} ) if Options.fingerprint?

        spider.peer_done( url ) if data[:crawl_done]
        slave_done( url, token ) if data[:audit_done]

        true
    end

    private

    #
    # @note Should previously unseen elements dynamically appear during the
    #   audit they will override audit restrictions and each instance will audit
    #   them at will.
    #
    # If we're the master we'll need to analyze the pages prior to assigning
    # them to each instance at the element level so as to gain more granular
    # control over the assigned workload.
    #
    # Put simply, we'll need to perform some magic in order to prevent different
    # instances from auditing the same elements and wasting bandwidth.
    #
    # For example: Search forms, logout links and the like will most likely
    # exist on most pages of the site and since each instance is assigned a set
    # of URLs/pages to audit they will end up with common elements so we have to
    # prevent instances from performing identical checks.
    #
    def master_run
        # We need to take our cues from the local framework as some plug-ins may
        # need the system to wait for them to finish before moving on.
        sleep( 0.2 ) while paused?

        # Prepare a block to process each Dispatcher and request slave instances
        # from it. If we have any available Dispatchers that is...
        each = proc do |d_url, iterator|
            d_opts = {
                'rank'   => 'slave',
                'target' => @opts.url,
                'master' => multi_self_url
            }

            print_status "Requesting Instance from Dispatcher: #{d_url}"
            connect_to_dispatcher( d_url ).
                dispatch( multi_self_url, d_opts, false ) do |instance_hash|
                    enslave( instance_hash ){ |b| iterator.next }
            end
        end

        after = proc do
            # Some options need to be adjusted when performing multi-Instance
            # scans for them to be enforced properly.
            adjust_distributed_options do
                master_scan_run
            end
        end

        # If there is no grid go straight to the scan, don't bother with
        # Grid-related operations.
        if !@opts.grid?
            after.call
        else
            # Get slaves from Dispatchers with unique Pipe IDs in order to take
            # advantage of line aggregation if we're in aggregation mode.
            if @opts.grid_aggregate?
                print_info 'In Grid line-aggregation mode, will only request' <<
                            ' Instances from Dispatcher with unique Pipe-IDs.'

                preferred_dispatchers do |pref_dispatchers|
                    iterator_for( pref_dispatchers ).each( each, after )
                end

            # If were not in aggregation mode then we're in load balancing mode
            # and that is handled better by our Dispatcher so ask it for slaves.
            else
                print_info 'In Grid load-balancing mode, letting our Dispatcher' <<
                            ' sort things out.'

                q = Queue.new
                @opts.max_slaves.times do
                    dispatcher.dispatch( multi_self_url ) do |instance_info|
                        enslave( instance_info ){ |b| q << true }
                    end
                end

                @opts.max_slaves.times { q.pop }
                after.call
            end
        end
    end

    def master_scan_run
        @status = :crawling

        Thread.abort_on_exception = true

        spider.on_each_page do |page|
            if page.platforms.any?
                print_info "Identified as: #{page.platforms.to_a.join( ', ' )}"
            end

            # Update the list of element scope-IDs per page -- will be used
            # as a whitelist for the distributed audit.
            update_element_ids_per_url(
                { page.url => build_elem_list( page ) },
                @local_token
            )
        end

        spider.on_complete do
            print_status 'Crawl finished, progressing to distribution of audit workload.'

            # Guess what we're doing now...
            @status = :distributing

            # The plugins may have updated the page queue so we need to take
            # these pages into account as well.
            page_a = []
            while !@page_queue.empty? && (page = @page_queue.pop)
                page_a << page
                update_element_ids_per_url(
                    { page.url => build_elem_list( page ) },
                    @local_token
                )
            end

            # Nothing to audit, bail out early...
            if @element_ids_per_url.empty?
                print_status 'No auditable elements found, cleaning up.'
                clean_up
                next
            end

            page_cnt    = @element_ids_per_url.size
            element_cnt = 0
            @element_ids_per_url.each { |_, v| element_cnt += v.size }
            print_info "Found #{page_cnt} pages with a total of #{element_cnt} elements."
            print_line

            # Split the URLs of the pages in equal chunks.
            chunks    = split_urls( @element_ids_per_url.keys, @instances.size + 1 )
            chunk_cnt = chunks.size

            # Split the page array into chunks that will be distributed across
            # the instances.
            page_chunks = page_a.chunk( chunk_cnt )

            # Assign us our fair share of plug-in discovered pages.
            update_page_queue( page_chunks.pop, @local_token )

            # What follows can be pretty resource intensive so don't block.
            Thread.new do
                # Remove duplicate elements across the (per instance) chunks while
                # spreading them out evenly.
                elements = distribute_elements( chunks, @element_ids_per_url )

                print_info "#{self_url} (Master)"
                print_info "  * #{chunks.first.size} URLs"

                # Set the URLs to be audited by the local instance.
                @opts.restrict_paths = chunks.shift

                print_info "  * #{elements.first.size} elements"
                print_line

                # Restrict the local instance to its assigned elements.
                restrict_to_elements( elements.shift, @local_token )

                # Distribute the audit workload and tell the slaves to have at it.
                chunks.each_with_index do |chunk, i|
                    instance_info = @instances[i]

                    print_info "#{instance_info[:url]} (Slave)"
                    print_info "  * #{chunk.size} URLs"
                    print_info "  * #{elements.first.size} elements"
                    print_line

                    distribute_and_run( instance_info,
                                        urls:     chunk,
                                        elements: elements.shift,
                                        pages:    page_chunks.shift )
                end

                # Start the master/local Instance's audit.
                audit

                @finished_auditing = true

                # Don't ring our own bell unless there are no other instances
                # set to scan or we have slaves running.
                #
                # If the local audit finishes super-fast the slaves might
                # not have been added to the local list yet, which will result
                # in us prematurely cleaning up and setting the status to
                # 'done' even though the slaves won't have yet finished
                #
                # However, if the workload chunk is 1 then no slaves will
                # have been started in the first place and since it's just us
                # we can go ahead and clean-up.
                cleanup_if_all_done if chunk_cnt == 1 || @running_slaves.any?
            end
        end

        # Let crawlers know of each other and start the master crawler.
        # The master will then push paths to its slaves thus waking them up
        # to join the crawl.
        spider.update_peers( @instances ) do
            Thread.new { spider.run }
        end
    end

    def adjust_distributed_options( &block )
        updated_opts = {}

        options = RPC::Server::ActiveOptions.new( self )

        # Adjust the values of options that require special care
        # when distributing.
        %w(link_count_limit http_req_limit).each do |name|
            next if !(v = options.send( name ))
            updated_opts[name] = v / (@instances.size + 1)
        end

        options.set updated_opts

        each = proc do |instance, iterator|
            instance.opts.set( updated_opts ) { iterator.next }
        end

        each_slave( each, block )
    end

    # Cleans up the system if all Instances have finished.
    def cleanup_if_all_done
        return if !@finished_auditing || @running_slaves != @done_slaves

        # We pass a block because we want to perform a grid cleanup, not just a
        # local one.
        clean_up{}
    end

    def has_slaves?
        @instances && @instances.any?
    end

    def auditstore_sitemap
        spider.sitemap
    end

end

end
end
