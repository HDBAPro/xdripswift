import Foundation
import os
import UIKit
import xDrip4iOS_Widget

public class NightScoutUploadManager: NSObject {
    
    // MARK: - properties
    
    /// path for readings and calibrations
    private let nightScoutEntriesPath = "/api/v1/entries"
    
    /// path for treatments
    private let nightScoutTreatmentPath = "/api/v1/treatments"
    
    /// path for devicestatus
    private let nightScoutDeviceStatusPath = "/api/v1/devicestatus"
    
    /// path to test API Secret
    private let nightScoutAuthTestPath = "/api/v1/experiments/test"

    /// for logging
    private var oslog = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryNightScoutUploadManager)
    
    /// BgReadingsAccessor instance
    private let bgReadingsAccessor:BgReadingsAccessor
    
    /// SensorsAccessor instance
    private let sensorsAccessor: SensorsAccessor
    
    /// CalibrationsAccessor instance
    private let calibrationsAccessor: CalibrationsAccessor
	
	/// TreatmentEntryAccessor
	private let treatmentEntryAccessor: TreatmentEntryAccessor
    
    /// reference to coreDataManager
    private let coreDataManager: CoreDataManager
    
    /// to solve problem that sometemes UserDefaults key value changes is triggered twice for just one change
    private let keyValueObserverTimeKeeper:KeyValueObserverTimeKeeper = KeyValueObserverTimeKeeper()
    
    /// in case errors occur like credential check error, then this closure will be called with title and message
    private let messageHandler:((String, String) -> Void)?
    
    /// temp storage transmitterBatteryInfo, if changed then upload to NightScout will be done
    private var latestTransmitterBatteryInfo: TransmitterBatteryInfo?
    
    /// temp storate uploader battery level, if changed then upload to NightScout will be done
    private var latestUploaderBatteryLevel: Float?
    
    /// - when was the sync of treatments with NightScout started.
    /// - if nil then there's no sync running
    /// - if not nil then the value tells when nightscout sync was started, without having finished (otherwise it should be nil)
    private var nightScoutTreatmentsSyncStartTimeStamp: Date?
    
    /// if nightScoutTreatmentsSyncStartTimeStamp is not nil, and more than this TimeInterval from now, then we can assume nightscout sync has failed during a previous attempt
    ///
    /// normally nightScoutTreatmentsSyncStartTimeStamp should be nil if it failed, but it could be due to a coding error that the value is not reset to nil
    private let maxDurationNightScoutTreatmentsSync = TimeInterval(minutes: 1)
    
    /// a sync may have started, and while running, the user may have created a new treatment. In that case, a sync will not be restarted, but wait till the previous is finished. This variable is used to verify if a new sync is required after having finished one
    ///
    /// Must be read/written in main thread !!
    private var nightScoutTreatmentSyncRequired = false
    
    // MARK: - initializer
    
    /// initializer
    /// - parameters:
    ///     - coreDataManager : needed to get latest readings
    ///     - messageHandler : to show the result of the sync to the user. this closure will be called with title and message
    init(coreDataManager: CoreDataManager, messageHandler:((_ timessageHandlertle:String, _ message:String) -> Void)?) {
        
        // init properties
        self.coreDataManager = coreDataManager
        self.bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        self.calibrationsAccessor = CalibrationsAccessor(coreDataManager: coreDataManager)
        self.messageHandler = messageHandler
        self.sensorsAccessor = SensorsAccessor(coreDataManager: coreDataManager)
		self.treatmentEntryAccessor = TreatmentEntryAccessor(coreDataManager: coreDataManager)
        
        super.init()
        
        // add observers for nightscout settings which may require testing and/or start upload
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutAPIKey.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutUrl.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutPort.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutEnabled.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutUseSchedule.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutSchedule.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightscoutToken.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutSyncTreatmentsRequired.rawValue, options: .new, context: nil)
    }
    
    // MARK: - public functions
    
    /// uploads latest BgReadings, calibrations, active sensor and battery status to NightScout, only if nightscout enabled, not master, url and key defined, if schedule enabled then check also schedule
    /// - parameters:
    ///     - lastConnectionStatusChangeTimeStamp : when was the last transmitter dis/reconnect
    public func uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: Date?) {
                
        // check that NightScout is enabled
        // and master is enabled
        // and nightScoutUrl exists
        guard UserDefaults.standard.nightScoutEnabled, UserDefaults.standard.isMaster, UserDefaults.standard.nightScoutUrl != nil else {return}
        
        // check that either the API_SECRET or Token exists, if both are nil then return
        if UserDefaults.standard.nightScoutAPIKey == nil && UserDefaults.standard.nightscoutToken == nil {
            return
        }
        
        // if schedule is on, check if upload is needed according to schedule
        if UserDefaults.standard.nightScoutUseSchedule {
            if let schedule = UserDefaults.standard.nightScoutSchedule {
                if !schedule.indicatesOn(forWhen: Date()) {
                    return
                }
            }
        }
        
        // upload readings
        uploadBgReadingsToNightScout(lastConnectionStatusChangeTimeStamp: lastConnectionStatusChangeTimeStamp)
        
        // upload calibrations
        uploadCalibrationsToNightScout()
        
        // upload activeSensor if needed
        if UserDefaults.standard.uploadSensorStartTimeToNS, let activeSensor = sensorsAccessor.fetchActiveSensor() {
            
            if !activeSensor.uploadedToNS  {

                trace("in upload, activeSensor not yet uploaded to NS", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)

                uploadActiveSensorToNightScout(sensor: activeSensor)

            }
        }
        
        // upload transmitter battery info if needed, also upload uploader battery level
        UIDevice.current.isBatteryMonitoringEnabled = true
        if UserDefaults.standard.transmitterBatteryInfo != latestTransmitterBatteryInfo || latestUploaderBatteryLevel != UIDevice.current.batteryLevel {
            
            if let transmitterBatteryInfo = UserDefaults.standard.transmitterBatteryInfo {

                uploadTransmitterBatteryInfoToNightScout(transmitterBatteryInfo: transmitterBatteryInfo)

            }
            
        }
        
    }
    
    /// synchronize treatments with NightScout
    public func syncTreatmentsWithNightScout() {
        
        // if sync already running, then set nightScoutTreatmentSyncRequired to true
        // sync is running already, once stopped it will rerun
        if let nightScoutTreatmentsSyncStartTimeStamp = nightScoutTreatmentsSyncStartTimeStamp {
            
            if (Date()).timeIntervalSince(nightScoutTreatmentsSyncStartTimeStamp) < maxDurationNightScoutTreatmentsSync {
                
                trace("in syncTreatmentsWithNightScout but previous sync still running. Sync will be started after finishing the previous sync", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                
                nightScoutTreatmentSyncRequired = true
                
                return
                
            }
            
        }
        
        // get the latest treatments from the last maxTreatmentsDaysToUpload days
        // filter by uploaded = false
        // this gives treatments that are not yet uploaded to NS and treatments that are already updated but were updated in xDrip4iOS and need be updated @ NS
        let treatmentsToUploadOrUpdate = treatmentEntryAccessor.getLatestTreatments(limit: ConstantsNightScout.maxTreatmentsToUpOrDownload).filter { treatment in
            return !treatment.uploaded }

        trace("in syncTreatmentsWithNightScout", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
        
        // *********************************************************************
        // start with uploading treatments that are in status not uploaded and have no id yet (ie never uploaded to NS before)
        // *********************************************************************
        trace("calling uploadTreatmentsToNightScout", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
        
        uploadTreatmentsToNightScout(treatmentsToUpload: treatmentsToUploadOrUpdate.filter { treatment in return treatment.id == TreatmentEntry.EmptyId}) {nightScoutResult in

            trace("    result = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, nightScoutResult.description())

            // possibly not running on main thread here
            DispatchQueue.main.async {

                // *********************************************************************
                // update treatments to nightscout
                // now filter on treatments that are in status not uploaded and have an id. These are treatments are already uploaded but need update @ NightScout
                // *********************************************************************
                
                // create new array of treatmentEntries to update - they will be processed one by one, a processed element is removed
                var treatmentsToUpdate = treatmentsToUploadOrUpdate.filter { treatment in return treatment.id != TreatmentEntry.EmptyId && !treatment.uploaded }
                
                trace("there are %{public}@ treatments to be updated", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, treatmentsToUpdate.count.description)
                
                // function to update the treatments one by one, it will call itself after having updated an entry, to process the next entry or to proceed with the next step in the sync process
                func updateTreatment() {
                    
                    if let treatmentToUpdate = treatmentsToUpdate.first {
                        
                        // remove the treatment from the array, so it doesn't get processed again next run
                        treatmentsToUpdate.removeFirst()
                        
                        trace("calling updateTreatmentToNightScout", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                        
                        self.updateTreatmentToNightScout(treatmentToUpdate: treatmentToUpdate, completionHandler: { nightScoutResult in
                            
                            trace("    result = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, nightScoutResult.description())
                            
                            // by calling updateTreatment(), the next treatment to update will be processed, or go to the next step in the sync process
                            // better to start in main thread
                            DispatchQueue.main.async {
                                updateTreatment()
                            }
                            
                        })
                        
                    } else {
                        
                        
                        // *********************************************************************
                        // download treatments from nightscout
                        // filter again on treatments that are in status not uploaded and have no id yet (ie never uploaded to NS before), because the goal is to find any missing id's if applicable
                        // *********************************************************************
                        trace("calling getLatestTreatmentsNSResponses", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                        
                        self.getLatestTreatmentsNSResponses(treatmentsToUpload: treatmentsToUploadOrUpdate.filter { treatment in return treatment.id == TreatmentEntry.EmptyId}) { nightScoutResult in
                            
                            trace("    result = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, nightScoutResult.description())
                            
                            DispatchQueue.main.async {
                                
                                // ***********************
                                // next step in the sync process
                                // sync again if necessary (user may have created or updated treatments while previous sync was running)
                                // ***********************
                                if self.nightScoutTreatmentSyncRequired {
                                    
                                    self.nightScoutTreatmentSyncRequired = false
                                    
                                    self.syncTreatmentsWithNightScout()
                                    
                                }

                            }
                            
                        }

                    }
                    
                }
                
                // call the function update Treatment a first time
                // it will call itself per Treatment to be updated at NightScout, or, if there aren't any to update, it will continue with the next step
                updateTreatment()
                                
            }
            
        }
        
    }
    
    // MARK: - overriden functions
    
    /// when one of the observed settings get changed, possible actions to take
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        if let keyPath = keyPath {
            if let keyPathEnum = UserDefaults.Key(rawValue: keyPath) {
                
                switch keyPathEnum {
                case UserDefaults.Key.nightScoutUrl, UserDefaults.Key.nightScoutAPIKey, UserDefaults.Key.nightscoutToken, UserDefaults.Key.nightScoutPort :
                    // apikey or nightscout api key change is triggered by user, should not be done within 200 ms
                    
                    if (keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 200)) {
                        
                        // if master is set, siteURL exists and either API_SECRET or a token is entered, then test credentials
                        if UserDefaults.standard.nightScoutUrl != "" && UserDefaults.standard.isMaster && (UserDefaults.standard.nightScoutAPIKey != "" || UserDefaults.standard.nightscoutToken != "") {
                            
                            testNightScoutCredentials({ (success, error) in
                                DispatchQueue.main.async {
                                    self.callMessageHandler(withCredentialVerificationResult: success, error: error)
                                    if success {
                                        
                                        // set lastConnectionStatusChangeTimeStamp to as late as possible, to make sure that the most recent reading is uploaded if user is testing the credentials
                                        self.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: Date())
                                        
                                    } else {
                                        trace("in observeValue, NightScout credential check failed", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                                    }
                                }
                            })
                        }
                    }
                    
                case UserDefaults.Key.nightScoutEnabled, UserDefaults.Key.nightScoutUseSchedule, UserDefaults.Key.nightScoutSchedule :
                    
                    // if changing to enabled, then do a credentials test and if ok start upload, in case of failure don't give warning, that's the only difference with previous cases
                    if (keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 200)) {
                        
                        // if master is set, siteURL exists and either API_SECRET or a token is entered, then test credentials
                        if UserDefaults.standard.nightScoutUrl != "" && UserDefaults.standard.isMaster && (UserDefaults.standard.nightScoutAPIKey != "" || UserDefaults.standard.nightscoutToken != "") {
                            
                            testNightScoutCredentials({ (success, error) in
                                DispatchQueue.main.async {
                                    if success {
                                        
                                        // set lastConnectionStatusChangeTimeStamp to as late as possible, to make sure that the most recent reading is uploaded if user is testing the credentials
                                        self.uploadLatestBgReadings(lastConnectionStatusChangeTimeStamp: Date())
                                        
                                    } else {
                                        trace("in observeValue, NightScout credential check failed", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                                    }
                                }
                            })
                        }
                    }
                    
                case UserDefaults.Key.nightScoutSyncTreatmentsRequired :
                    // if value is set to true, then a nightscout sync is required
                    if (UserDefaults.standard.nightScoutSyncTreatmentsRequired && keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 200)) {

                        UserDefaults.standard.nightScoutSyncTreatmentsRequired = false
                        
                        syncTreatmentsWithNightScout()

                    }
                    
                default:
                    break
                }
            }
        }
    }
    
    // MARK: - private helper functions
    
    /// upload battery level to nightscout
    /// - parameters:
    ///     - siteURL : nightscout site url
    ///     - apiKey : nightscout api key
    ///     - transmitterBatteryInfosensor: setransmitterBatteryInfosensornsor to upload
    private func uploadTransmitterBatteryInfoToNightScout(transmitterBatteryInfo: TransmitterBatteryInfo) {
        
        trace("in uploadTransmitterBatteryInfoToNightScout, transmitterBatteryInfo not yet uploaded to NS", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
        
        // enable battery monitoring on iOS device
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        // https://testhdsync.herokuapp.com/api-docs/#/Devicestatus/addDevicestatuses
        let transmitterBatteryInfoAsKeyValue = transmitterBatteryInfo.batteryLevel
        
        // not very clear here how json should look alike. For dexcom it seems to work with "battery":"the battery level off the iOS device" and "batteryVoltage":"Dexcom voltage"
        // while for other devices like MM and Bubble, there's no batterVoltage but also a battery, so for this case I'm using "battery":"transmitter battery level", otherwise there's two "battery" keys which causes a crash - I'll hear if if it's not ok
        // first assign dataToUpload assuming the key for transmitter battery will be "battery" (ie it's not a dexcom)
        var dataToUpload = [
            "uploader" : [
                "name" : "transmitter",
                "battery" : transmitterBatteryInfoAsKeyValue.value
            ]
        ] as [String : Any]
        
        // now check if the key for transmitter battery is not "battery" and if so reassign dataToUpload now with battery being the iOS devices battery level
        if transmitterBatteryInfoAsKeyValue.key != "battery" {
            dataToUpload = [
                "uploader" : [
                    "name" : "transmitter",
                    "battery" : Int(UIDevice.current.batteryLevel * 100.0),
                    transmitterBatteryInfoAsKeyValue.key : transmitterBatteryInfoAsKeyValue.value
                ]
            ]
        }
        
        
        uploadData(dataToUpload: dataToUpload, httpMethod: nil, path: nightScoutDeviceStatusPath, completionHandler: {
        
            // sensor successfully uploaded, change value in coredata
            trace("in uploadTransmitterBatteryInfoToNightScout, transmitterBatteryInfo uploaded to NS", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
            
            self.latestTransmitterBatteryInfo = transmitterBatteryInfo
            
            self.latestUploaderBatteryLevel = UIDevice.current.batteryLevel

        })
        
    }

    /// upload sensor to nightscout
    /// - parameters:
    ///     - sensor: sensor to upload
    private func uploadActiveSensorToNightScout(sensor: Sensor) {
        
        trace("in uploadActiveSensorToNightScout, activeSensor not yet uploaded to NS", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
        
        let dataToUpload = [
            "_id": sensor.id,
            "eventType": "Sensor Start",
            "created_at": sensor.startDate.ISOStringFromDate(),
            "enteredBy": ConstantsHomeView.applicationName
        ]
        
        uploadData(dataToUpload: dataToUpload, httpMethod: nil, path: nightScoutTreatmentPath, completionHandler: {
            
            // sensor successfully uploaded, change value in coredata
            trace("in uploadActiveSensorToNightScout, activeSensor uploaded to NS", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
            
            DispatchQueue.main.async {
                
                sensor.uploadedToNS = true
                self.coreDataManager.saveChanges()

            }
            
        })
        
    }
    
    /// upload latest readings to nightscout
    /// - parameters:
    ///     - lastConnectionStatusChangeTimeStamp : if there's not been a disconnect in the last 5 minutes, then the latest reading will be uploaded only if the time difference with the latest but one reading is at least 5 minutes.
    private func uploadBgReadingsToNightScout(lastConnectionStatusChangeTimeStamp: Date?) {
        
        trace("in uploadBgReadingsToNightScout", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
        
        // get readings to upload, limit to x days, x = ConstantsNightScout.maxBgReadingsDaysToUpload
        var timeStamp = Date(timeIntervalSinceNow: TimeInterval(-ConstantsNightScout.maxBgReadingsDaysToUpload))
        
        if let timeStampLatestNightScoutUploadedBgReading = UserDefaults.standard.timeStampLatestNightScoutUploadedBgReading {
            if timeStampLatestNightScoutUploadedBgReading > timeStamp {
                timeStamp = timeStampLatestNightScoutUploadedBgReading
            }
        }
        
        // get latest readings, filter : minimiumTimeBetweenTwoReadingsInMinutes beteen two readings, except for the first if a dis/reconnect occured since the latest reading
        var bgReadingsToUpload = bgReadingsAccessor.getLatestBgReadings(limit: nil, fromDate: timeStamp, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false).filter(minimumTimeBetweenTwoReadingsInMinutes: ConstantsNightScout.minimiumTimeBetweenTwoReadingsInMinutes, lastConnectionStatusChangeTimeStamp: lastConnectionStatusChangeTimeStamp, timeStampLastProcessedBgReading: timeStamp)
        
        if bgReadingsToUpload.count > 0 {
            trace("    number of readings to upload : %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, bgReadingsToUpload.count.description)
            
            // there's a limit of payload size to upload to NightScout
            // if size is > maximum, then we'll have to call the upload function again, this variable will be used in completionHandler
            let callAgainNeeded = bgReadingsToUpload.count > ConstantsNightScout.maxReadingsToUpload
            
            if callAgainNeeded {
                trace("    restricting readings to upload to %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, ConstantsNightScout.maxReadingsToUpload.description)
            }

            // limit the amount of readings to upload to avoid passing this limit
            // we start with the oldest readings
            bgReadingsToUpload = bgReadingsToUpload.suffix(ConstantsNightScout.maxReadingsToUpload)
            
            // map readings to dictionaryRepresentation
            let bgReadingsDictionaryRepresentation = bgReadingsToUpload.map({$0.dictionaryRepresentationForNightScoutUpload})
            
            // store the timestamp of the last reading to upload, here in the main thread, because we use a bgReading for it, which is retrieved in the main mangedObjectContext
            let timeStampLastReadingToUpload = bgReadingsToUpload.first != nil ? bgReadingsToUpload.first!.timeStamp : nil
            
            uploadData(dataToUpload: bgReadingsDictionaryRepresentation, httpMethod: nil, path: nightScoutEntriesPath, completionHandler: {
                
                // change timeStampLatestNightScoutUploadedBgReading
                if let timeStampLastReadingToUpload = timeStampLastReadingToUpload {
                    
                    trace("    in uploadBgReadingsToNightScout, upload succeeded, setting timeStampLatestNightScoutUploadedBgReading to %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, timeStampLastReadingToUpload.description(with: .current))
                    
                    UserDefaults.standard.timeStampLatestNightScoutUploadedBgReading = timeStampLastReadingToUpload
                    
                    // callAgainNeeded means we've limit the amount of readings because size was too big
                    // if so a new upload is needed
                    if callAgainNeeded {
                        
                        // do this in the main thread because the readings are fetched with the main mainManagedObjectContext
                        DispatchQueue.main.async {
                        
                            self.uploadBgReadingsToNightScout(lastConnectionStatusChangeTimeStamp: lastConnectionStatusChangeTimeStamp)
                            
                        }
                        
                    }
                    
                }
                
            })
            
        } else {
            trace("    no readings to upload", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
        }
        
    }

    /// update one single treatment to nightscout
    /// - parameters:
    ///     - completionHandler : to be called after completion, takes NightScoutResult as argument
    ///     - treatmentToUpdate : treament to update
    private func updateTreatmentToNightScout(treatmentToUpdate: TreatmentEntry, completionHandler: (@escaping (_ nightScoutResult: NightScoutResult) -> Void)) {
        
        trace("in updateTreatmentsToNightScout", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
        
            uploadDataAndGetResponse(dataToUpload: treatmentToUpdate.dictionaryRepresentationForNightScoutUpload(), httpMethod: "PUT", path: nightScoutTreatmentPath) { (responseData: Data?, result: NightScoutResult) in
                
                self.coreDataManager.mainManagedObjectContext.performAndWait {

                    if result.successFull() {
                        treatmentToUpdate.uploaded = true
                        self.coreDataManager.saveChanges()
                    }

                }
                
                completionHandler(result)
                
            }
        
    }
    
    /// Upload treatments to nightscout, receives the JSON response with the asigned id's and sets the id's in Coredata.
	/// - parameters:
    ///     - completionHandler : to be called after completion, takes NightScoutResult as argument
    ///     - treatmentsToUpload : treaments to upload
    private func uploadTreatmentsToNightScout(treatmentsToUpload: [TreatmentEntry], completionHandler: (@escaping (_ nightScoutResult: NightScoutResult) -> Void)) {
        
		trace("in uploadTreatmentsToNightScout", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
		
		guard treatmentsToUpload.count > 0 else {
            
			trace("    no treatments to upload", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
            
            completionHandler(NightScoutResult.success(.withoutlocalchanges))
            
			return
            
		}
	
		trace("    number of treatments to upload : %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, treatmentsToUpload.count.description)
		
		// map treatments to dictionaryRepresentation
		let treatmentsDictionaryRepresentation = treatmentsToUpload.map({$0.dictionaryRepresentationForNightScoutUpload()})
		
		// The responsedata will contain, in serialized json, the treatments ids assigned by the server.
        uploadDataAndGetResponse(dataToUpload: treatmentsDictionaryRepresentation, httpMethod: nil, path: nightScoutTreatmentPath) { (responseData: Data?, result: NightScoutResult) in
			
            // if result of uploadDataAndGetResponse is not success then just return the result without further processing
            guard result.successFull() else {
                completionHandler(result)
                return
            }
            
			do {
                
                guard let responseData = responseData else {
                    
                    trace("    responseData is nil", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                    
                    completionHandler(NightScoutResult.failed)
                    
                    return
                    
                }
                
				// Try to serialize the data
				if let treatmentNSresponses = try TreatmentNSResponse.arrayFromData(responseData) {
                    
					// run in main thread because TreatmenEntry instances are craeted or updated
					self.coreDataManager.mainManagedObjectContext.performAndWait {

                        let amount = self.checkIfUploaded(forTreatmentEntries: treatmentsToUpload, inTreatmentNSResponses: treatmentNSresponses)

                        trace("    %{public}@ treatmentEntries uploaded", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, amount.description)

						self.coreDataManager.saveChanges()
                        
                        completionHandler(NightScoutResult.success(.withoutlocalchanges))
                        
					}
					
                } else {
                    
                    if let responseDataAsString = String(bytes: responseData, encoding: .utf8) {
                        
                        trace("    json serialization failed. responseData = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, responseDataAsString)
                        
                    }
                    
                    // json serialization failed, so call completionhandler with success = false
                    completionHandler(.failed)
                                        
                }
                
			} catch let error {
                
				trace("    uploadTreatmentsToNightScout error at JSONSerialization : %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .error, error.localizedDescription)
                
                completionHandler(.failed)
                
			}
            
		}
		
    }
    
    /// upload latest calibrations to nightscout
    /// - parameters:
    private func uploadCalibrationsToNightScout() {
        
        trace("in uploadCalibrationsToNightScout", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
        
        // get the calibrations from the last maxDaysToUpload days
        let calibrations = calibrationsAccessor.getLatestCalibrations(howManyDays: Int(ConstantsNightScout.maxBgReadingsDaysToUpload.days), forSensor: nil)
        
        var calibrationsToUpload: [Calibration] = []
        if let timeStampLatestNightScoutUploadedCalibration = UserDefaults.standard.timeStampLatestNightScoutUploadedCalibration {
            // select calibrations that are more recent than the latest uploaded calibration
            calibrationsToUpload = calibrations.filter({$0.timeStamp > timeStampLatestNightScoutUploadedCalibration })
        }
        else {
            // or all calibrations if there is no previously uploaded calibration
            calibrationsToUpload = calibrations
        }
        
        if calibrationsToUpload.count > 0 {
            trace("    number of calibrations to upload : %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, calibrationsToUpload.count.description)
            
            // map calibrations to dictionaryRepresentation
            // 2 records are uploaded to nightscout for each calibration: a cal record and a mbg record
            let calibrationsDictionaryRepresentation = calibrationsToUpload.map({$0.dictionaryRepresentationForCalRecordNightScoutUpload}) + calibrationsToUpload.map({$0.dictionaryRepresentationForMbgRecordNightScoutUpload})
            
            // store the timestamp of the last calibration to upload, here in the main thread, because we use a Calibration for it, which is retrieved in the main mangedObjectContext
            let timeStampLastCalibrationToUpload = calibrationsToUpload.first != nil ? calibrationsToUpload.first!.timeStamp : nil

            uploadData(dataToUpload: calibrationsDictionaryRepresentation, httpMethod: nil, path: nightScoutEntriesPath, completionHandler: {
                
                // change timeStampLatestNightScoutUploadedCalibration
                if let timeStampLastCalibrationToUpload = timeStampLastCalibrationToUpload {
                    
                    trace("    in uploadCalibrationsToNightScout, upload succeeded, setting timeStampLatestNightScoutUploadedCalibration to %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, timeStampLastCalibrationToUpload.description(with: .current))
                    
                    UserDefaults.standard.timeStampLatestNightScoutUploadedCalibration = timeStampLastCalibrationToUpload
                    
                }
                
            })
            
        } else {
            trace("    no calibrations to upload", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
        }
        
    }
	
	/// Gets the latest treatments from Nightscout
	/// - parameters:
	///     - completionHandler : handler that will be called with the result TreatmentNSResponse array
    ///     - treatmentsToUpload : main goal of the function is not to upload, but to download. However the response will be used to verify if it has any of the treatments that has no id yet
	private func getLatestTreatmentsNSResponses(treatmentsToUpload: [TreatmentEntry], completionHandler: (@escaping (_ result: NightScoutResult) -> Void)) {
        
        trace("in getLatestTreatmentsNSResponses", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)

        let queries = [URLQueryItem(name: "count", value: String(ConstantsNightScout.maxTreatmentsToUpOrDownload))]
        
		getRequest(path: nightScoutTreatmentPath, queries: queries) { (data: Data?) in
			
			guard let data = data else {
                trace("    data is nil", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .error)
                completionHandler(.failed)
				return
			}
			
            // trace data to upload as string in debug  mode
            if let dataAsString = String(bytes: data, encoding: .utf8) {
                trace("    data : %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .debug, dataAsString)
            }
            
			do {
                
				// Try to serialize the data
				if let treatmentNSResponses = try TreatmentNSResponse.arrayFromData(data) {
                    
                    // Be sure to use the correct thread.
                    // Running in the completionHandler thread will result in issues.
                    self.coreDataManager.mainManagedObjectContext.performAndWait {
                        
                        trace("    %{public}@ treatments downloaded", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, treatmentNSResponses.count.description)
                        
                        // if there's nothing in treatmentNSResponses, then no need for further processing
                        guard treatmentNSResponses.count > 0 else {
                            
                            completionHandler(NightScoutResult.success(.withoutlocalchanges))
                            
                            return
                            
                        }
                        
                        // newTreatmentsIfRequired will iterate through downloaded treatments and if any in it is not yet known then create an instance of TreatmentEntry for each new one
                        // amountOfNewTreatments is the amount of new TreatmentEntries, just for tracing
                        let amountOfNewTreatments  = self.newTreatmentsIfRequired(treatmentNSResponses: treatmentNSResponses)
                        
                        trace("    %{public}@ new treatmentEntries created", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, amountOfNewTreatments.description)
                        
                        // main goal of the function is not to upload, but to download. However the response from NS will be used to verify if it has any of the treatments that has no id yet in coredata
                        let amount = self.checkIfUploaded(forTreatmentEntries: treatmentsToUpload, inTreatmentNSResponses: treatmentNSResponses)
                        
                        trace("    %{public}@ treatmentEntries found in response which were not yet marked as uploaded", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, amount.description)

                        self.coreDataManager.saveChanges()
                        
                        // call completion handler with success, if amount and/or amountOfNewTreatments > 0 then it's success withlocalchanges
                        completionHandler(amount + amountOfNewTreatments > 0 ? NightScoutResult.success(.withlocalchanges) : NightScoutResult.success(.withoutlocalchanges))
                        
                    }

                    
                } else {
                    
                    if let dataAsString = String(bytes: data, encoding: .utf8) {
                        
                        trace("    json serialization failed. data = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, dataAsString)
                        
                        completionHandler(.failed)
                        
                    }
                    
                }
                
			} catch let error {
                
				trace("    getLatestTreatmentsNSResponses error at JSONSerialization : %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .error, error.localizedDescription)
                
                completionHandler(.failed)
                
			}
            
		}
        
	}
	
	
	
	/// common functionality to do a GET request to Nightscout and get response
	/// - parameters:
	///     - path : the query path
	///     - queries : an array of URLQueryItem (added after the '?' at the URL)
	///     - responseHandler : will be executed with the response Data? if successfull
	private func getRequest(path: String, queries: [URLQueryItem], responseHandler: ((Data?) -> Void)?) {
        
        guard let nightScoutUrl = UserDefaults.standard.nightScoutUrl else {
            trace("    nightScoutUrl is nil", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
            return
        }
        
		guard let url = URL(string: nightScoutUrl), var uRLComponents = URLComponents(url: url.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
			return
		}

		if UserDefaults.standard.nightScoutPort != 0 {
			uRLComponents.port = UserDefaults.standard.nightScoutPort
		}
			
		// Mutable copy used to add token if defined.
		var queryItems = queries
		// if token not nil, then add also the token
		if let token = UserDefaults.standard.nightscoutToken {
			queryItems.append(URLQueryItem(name: "token", value: token))
		}
		uRLComponents.queryItems = queryItems
		
		if let url = uRLComponents.url {
            
			// Create Request
			var request = URLRequest(url: url)
			request.httpMethod = "GET"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.setValue("application/json", forHTTPHeaderField: "Accept")
			
			if let apiKey = UserDefaults.standard.nightScoutAPIKey {
				request.setValue(apiKey.sha1(), forHTTPHeaderField:"api-secret")
			}
			
			let task = URLSession.shared.dataTask(with: request) { (data: Data?, urlResponse: URLResponse?, error: Error?) in
				
				// error cases
				if let error = error {
                    
					trace("    failed to upload, error = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .error, error.localizedDescription)
                    
                    return
                    
				}
                    
                if let hTTPURLResponse = urlResponse as? HTTPURLResponse {
                    
                    if hTTPURLResponse.statusCode == 200 {
                        
                        if let responseHandler = responseHandler {
                            responseHandler(data)
                        }
                        
                    } else {
                    
                        trace("    status code = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, hTTPURLResponse.statusCode.description)
                        
                    }
                    
                }
                
			}
            
			task.resume()
            
		}
        
	}
    
    /// common functionality to upload data to nightscout
    /// - parameters:
    ///     - dataToUpload : data to upload
    ///     - completionHandler : will be executed if upload was successful
    ///
    /// only used by functions to upload bg reading, calibrations, active sensor, battery status
    private func uploadData(dataToUpload: Any, httpMethod: String?, path: String, completionHandler: (() -> ())?) {
        
        uploadDataAndGetResponse(dataToUpload: dataToUpload, httpMethod: httpMethod, path: path) { _, nightScoutResult  in
            
			if let completionHandler = completionHandler {
                
				completionHandler()
                
			}
            
		}
        
    }

	/// common functionality to upload data to nightscout and get response
	/// - parameters:
	///     - dataToUpload : data to upload
    ///     - path : the path (like /api/v1/treatments)
    ///     - httpMethod : method to use, default POST
	///     - completionHandler : will be executed with the response Data? and NightScoutResult
    private func uploadDataAndGetResponse(dataToUpload: Any, httpMethod: String?, path: String, completionHandler: @escaping ((Data?, NightScoutResult) -> Void)) {
        
        do {
            
            // transform dataToUpload to json
            let dataToUploadAsJSON = try JSONSerialization.data(withJSONObject: dataToUpload, options: [])

            // trace size of data
            trace("    size of data to upload : %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, dataToUploadAsJSON.count.description)
            
            // trace data to upload as string in debug  mode
            if let dataToUploadAsJSONAsString = String(bytes: dataToUploadAsJSON, encoding: .utf8) {
                trace("    data to upload : %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .debug, dataToUploadAsJSONAsString)
            }
            
            if let nightScoutUrl = UserDefaults.standard.nightScoutUrl, let url = URL(string: nightScoutUrl), var uRLComponents = URLComponents(url: url.appendingPathComponent(path), resolvingAgainstBaseURL: false) {

                if UserDefaults.standard.nightScoutPort != 0 {
                    uRLComponents.port = UserDefaults.standard.nightScoutPort
                }
                
                // if token not nil, then add also the token
                if let token = UserDefaults.standard.nightscoutToken {
                    let queryItems = [URLQueryItem(name: "token", value: token)]
                    uRLComponents.queryItems = queryItems
                }
                
                if let url = uRLComponents.url {
                    
                    // Create Request
                    var request = URLRequest(url: url)
                    request.httpMethod = httpMethod ?? "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    
                    if let apiKey = UserDefaults.standard.nightScoutAPIKey {
                        request.setValue(apiKey.sha1(), forHTTPHeaderField:"api-secret")
                    }
                    
                    // Create upload Task
                    let urlSessionUploadTask = URLSession.shared.uploadTask(with: request, from: dataToUploadAsJSON, completionHandler: { (data, response, error) -> Void in
                        
                        trace("    finished upload", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                        
                        var dataAsString = "NO DATA RECEIVED"
                        if let data = data {
                            if let text = String(bytes: data, encoding: .utf8) {
                                dataAsString = text
                            }
                            
                        }
                        
                        // will contain result of nightscount sync
                        var nightScoutResult = NightScoutResult.success(.withoutlocalchanges)
                        
                        // before leaving the function, call completionhandler with result
                        // also trace either debug or error, depending on result
                        defer {
                            if !nightScoutResult.successFull() {
                                
                                trace("    data received = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .error, dataAsString)

                            } else {
                                
                                // add data received in debug level
                                trace("    data received = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .debug, dataAsString)
                                
                            }
                            
                            completionHandler(data, nightScoutResult)
                            
                        }
                        
                        // error cases
                        if let error = error {
                            trace("    failed to upload, error = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .error, error.localizedDescription)
                            return
                        }
                        
                        // check that response is HTTPURLResponse and error code between 200 and 299
                        if let response = response as? HTTPURLResponse {
                            guard (200...299).contains(response.statusCode) else {
                                
                                // if the statuscode = 500 and if data has error code 66 then consider this as successful
                                // it seems to happen sometimes that an attempt is made to re-upload readings that were already uploaded (meaning with same id). That gives error 66
                                // in that case consider the upload as successful
                                if response.statusCode == 500 {
                                    
                                    do {

                                        if let data = data, let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                                            
                                            // try to read description
                                            if let description = json["description"] as? [String: Any] {
                                                
                                                // try to read the code
                                                if let code = description["code"] as? Int {
                                                    
                                                    if code == 66 {
                                                        
                                                        trace("    found code = 66, considering the upload as successful", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .error)
                                                        
                                                        nightScoutResult = NightScoutResult.success(.withoutlocalchanges)
                                                        
                                                        return
                                                        
                                                    }
                                                    
                                                }
                                                
                                            }
                                            
                                        }

                                    } catch {
                                            // json decode fails, upload will be considered as failed
                                    }
                                    
                                }
                                                            
                                trace("    failed to upload, statuscode = %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .error, response.statusCode.description)
                                
                                return
                                
                            }
                        } else {
                            trace("    response is not HTTPURLResponse", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .error)
                        }
                        
                        // successful cases
                        nightScoutResult = NightScoutResult.success(.withoutlocalchanges)
                        
                    })
                    
                    trace("    calling urlSessionUploadTask.resume", log: oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                    urlSessionUploadTask.resume()
                    
                } else {
                    
                    // case where url is nil, which should normally not happen
                    completionHandler(nil, NightScoutResult.failed)
                    
                }
                
                
                
            } else {
                
                // case where nightScoutUrl is nil, which should normally not happen because nightScoutUrl was checked before calling this function
                completionHandler(nil, NightScoutResult.failed)
                
            }
            
        } catch let error {
            
            trace("     error : %{public}@", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info, error.localizedDescription)
            
        }

    }
    
    private func testNightScoutCredentials(_ completion: @escaping (_ success: Bool, _ error: Error?) -> Void) {
        
        if let nightSccoutUrl = UserDefaults.standard.nightScoutUrl, let url = URL(string: nightSccoutUrl), var uRLComponents = URLComponents(url: url.appendingPathComponent(nightScoutAuthTestPath), resolvingAgainstBaseURL: false) {
            
            if UserDefaults.standard.nightScoutPort != 0 {
                uRLComponents.port = UserDefaults.standard.nightScoutPort
            }
            
            if let url = uRLComponents.url {

                var request = URLRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField:"Content-Type")
                request.setValue("application/json", forHTTPHeaderField:"Accept")
                
                // if the API_SECRET is present, then hash it and pass it via http header. If it's missing but there is a token, then send this as plain text to allow the authentication check.
                if let apiKey = UserDefaults.standard.nightScoutAPIKey {
                    
                    request.setValue(apiKey.sha1(), forHTTPHeaderField:"api-secret")
                    
                } else if let token = UserDefaults.standard.nightscoutToken {
                    
                    request.setValue(token, forHTTPHeaderField:"api-secret")
                    
                }
                
                let task = URLSession.shared.dataTask(with: request, completionHandler: { (data, response, error) in
                    
                    trace("in testNightScoutCredentials, finished task", log: self.oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                    
                    if let error = error {
                        completion(false, error)
                        return
                    }
                    
                    if let httpResponse = response as? HTTPURLResponse ,
                       httpResponse.statusCode != 200, let data = data {
                        completion(false, NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: String.Encoding.utf8)!]))
                    } else {
                        completion(true, nil)
                    }
                })
                
                trace("in testNightScoutCredentials, calling task.resume", log: oslog, category: ConstantsLog.categoryNightScoutUploadManager, type: .info)
                task.resume()

            }
            
            
        }
    }
    
    private func callMessageHandler(withCredentialVerificationResult success:Bool, error:Error?) {
        
        // define the title text
        var title = TextsNightScout.verificationSuccessfulAlertTitle
        if !success {
            title = TextsNightScout.verificationErrorAlertTitle
        }
        
        // define the message text
        var message = TextsNightScout.verificationSuccessfulAlertBody
        if !success {
            if let error = error {
                message = error.localizedDescription
            } else {
                message = "unknown error"// shouldn't happen
            }
        }

        // call messageHandler
        if let messageHandler = messageHandler {
            messageHandler(title, message)
        }
        
    }
    
    /// Verifies for each treatmentEntriy, that is already uploaded, if any of the attributes has different values and if yes updates the TreatmentEntry locally
    /// - parameters:
    ///     - forTreatmentEntries : treatmentEntries to check if they have new values
    ///     - inTreatmentNSResponses : responses downloaded from NS, in which to search for the treatmentEntries
    /// - returns:amount of locally updated treatmentEntries
    ///
    /// - !! does not save to coredata
    private func checkIfChangedAtNS(forTreatmentEntries treatmentEntries: [TreatmentEntry], inTreatmentNSResponses treatmentNSResponses: [TreatmentNSResponse]) -> Int {
        
        // used to trace how many new treatmenEntries are locally updated
        var amountOfUpdatedTreatmentEntries = 0
        
        // iterate through treatmentEntries
        for treatmentEntry in treatmentEntries {
            
            // only handle treatmentEntries that are already uploaded
            if treatmentEntry.uploaded && treatmentEntry.id != TreatmentEntry.EmptyId {
                
                for treatmentNSResponse in treatmentNSResponses {
                    
                    // iterate through treatmentEntries
                    // find matching id
                    if treatmentNSResponse.id == treatmentEntry.id {
                        
                        var treatmentUpdated = false
                        
                        // check value, type and date. If NS has any difference, then update locally
                        
                        if treatmentNSResponse.value != treatmentEntry.value {
                            treatmentUpdated = true
                            treatmentEntry.value = treatmentNSResponse.value
                        }
                        
                        if treatmentNSResponse.eventType != treatmentEntry.treatmentType {
                            treatmentUpdated = true
                            treatmentEntry.treatmentType = treatmentNSResponse.eventType
                        }
                        
                        if treatmentNSResponse.createdAt != treatmentEntry.date {
                            treatmentUpdated = true
                            treatmentEntry.date = treatmentNSResponse.createdAt
                        }
                        
                        if treatmentUpdated {
                            amountOfUpdatedTreatmentEntries = amountOfUpdatedTreatmentEntries + 1
                        }
                        
                        break
                        
                    }
                    
                }
                
            }
            
        }
        
        return amountOfUpdatedTreatmentEntries
        
    }

    /// Verifies for each treatmentEntriy, if not yet uploaded and if empty id, then  if there is a matching  treatmentNSResponses and if yes reads the id (for new treatmentEntries) from the treatmentNSResponse and stores in the treatmentEntry
    /// - parameters:
    ///     - forTreatmentEntries : treatmentEntries to check if they are uploaded
    ///     - inTreatmentNSResponses : responses downloaded from NS, in which to search for the treatmentEntries
    /// - returns:amount of new  treatmentEntries found
    ///
    /// - !! does not save to coredata
    private func checkIfUploaded(forTreatmentEntries treatmentEntries: [TreatmentEntry], inTreatmentNSResponses treatmentNSResponses: [TreatmentNSResponse]) -> Int {
        
        // used to trace how many new treatmenEntries are created
        var amountOfNewTreatmentEntries = 0
        
        for treatmentEntry in treatmentEntries {
            
            if !treatmentEntry.uploaded && treatmentEntry.id == TreatmentEntry.EmptyId {
                
                for treatmentNSResponse in treatmentNSResponses {
                    
                    if treatmentNSResponse.matchesTreatmentEntry(treatmentEntry) {
                        
                        // Found the treatment
                        treatmentEntry.uploaded = true
                        
                        // Sets the id
                        treatmentEntry.id = treatmentNSResponse.id
                        
                        amountOfNewTreatmentEntries = amountOfNewTreatmentEntries + 1
                        
                        break
                        
                    }
                    
                }
                
            }
            
        }
        
        return amountOfNewTreatmentEntries
        
    }
    
    /// filters on treatments that are net yet known, and for those creates a TreatMentEntry
    /// - parameters:
    ///     - treatmentNSResponses : array of TreatmentNSResponse
    /// - returns: number of newly created TreatmentEntry's
    ///
    /// !! new treatments are stored in coredata after calling this function - no saveChanges to coredata is done here in this function
    private func newTreatmentsIfRequired(treatmentNSResponses: [TreatmentNSResponse]) -> Int {

        // returnvalue
        var numberOfNewTreatments = 0
        
        for treatmentNSResponse in treatmentNSResponses {
            
            if !self.treatmentEntryAccessor.existsTreatmentWithId(treatmentNSResponse.id) {
             
                if treatmentNSResponse.asNewTreatmentEntry(nsManagedObjectContext: coreDataManager.mainManagedObjectContext) != nil {
                    
                    numberOfNewTreatments = numberOfNewTreatments + 1
                    
                }

            }
        }
        
        return numberOfNewTreatments
        
    }
    
}

// MARK: - enum's

/// nightscout result
fileprivate enum NightScoutResult: Equatable {
    
    case success(NightScoutUploadDetails)
    
    case failed
    
    func description() -> String {
        switch self {
            
        case .success(let nightScoutUploadDetails):
            
            switch nightScoutUploadDetails {
            case .unknown:
                return "success"
            case .withoutlocalchanges:
                return "success with local changes"
            case .withlocalchanges:
                return "success without local changes"
            }
            
        case .failed:
            return "failed"
            
        }
        
    }
    
    /// returns result as bool, allows to check if successful or not without looking at details
    func successFull() -> Bool {
        switch self {
        case .success(_):
            return true
        case .failed:
            return false
        }
    }
    
}

/// used as subcase for NightScoutResult,
fileprivate enum NightScoutUploadDetails: Equatable {
    
    /// no treatments downloaded that required local creation of a new TreatmentEntry or update of an existing TreatmentEntry
    case withoutlocalchanges
    
    /// treatments downloaded that required local creation of a new TreatmentEntry or update of an existing TreatmentEntry
    case withlocalchanges
    
    /// unknown if treatments were downloaded or updated
    case unknown
    
    func description() -> String {
        switch self {
            
        case .unknown:
            return "unknowniflocalchanges"
            
        case .withoutlocalchanges:
            return "withoutlocalchanges"
            
        case .withlocalchanges:
            return "withlocalchanges"
            
        }
        
    }
    
}
