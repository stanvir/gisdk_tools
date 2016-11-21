/*
Uses the R package 'hmcr' to determine hourly capacities.

Input:
RScriptExe  String  Path to "Rscript.exe"
RScript     String  Path to "HCMCapacity.R"
hwyDBD      String  Full path of the highway geodatabase.  Must have fields:
  HCMType       ABLanes
  AreaType      BALanes
  PostedSpeed   Terrain
  HCMMedian
outputDir   String  Where the output csv will be located

Output:
HourlyCapacities            CSV Output directly from R
Highway Links with Errors   CSV Lists links with capacity errors
Appends capacities onto hwyDBD

Depends:
ModelUtilities.rsc    Uses the "Run R Script" macro
*/

Macro "Hourly Capacity" (RScriptExe, RScript, hwyDBD, outputDir)

  // Add the highway layer to workspace
  {nLyr, lLyr} = GetDBLayers(hwyDBD)
  lLyr = AddLayerToWorkspace(lLyr, hwyDBD, lLyr)

  // Check that the necessary fields are present
  a_fields = GetFields(lLyr, "All")
  a_fields = a_fields[1]
  a_reqFields = {
    "HCMType", "AreaType", "PostedSpeed", "HCMMedian", "ABLanes",
    "BALanes", "Terrain"
  }
  string = "The following fields are missing: "
  missing = "False"
  for i = 1 to a_reqFields.length do
    reqField = a_reqFields[i]

    opts = null
    opts.[Case Sensitive] = "True"
    if ArrayPosition(a_fields, {reqField}, opts) = null then do
      missing = "True"
      string = string + "'" + reqField + "' "
    end
  end
  if missing then do
    Throw(string)
  end

  // Prepare link layer for calculation
  a_fields = {{"ABHourlyCapD", "Integer", 10, },
              {"BAHourlyCapD", "Integer", 10, },
              {"ABHourlyCapE", "Integer", 10, },
              {"BAHourlyCapE", "Integer", 10, }}
  RunMacro("TCB Add View Fields", {lLyr, a_fields})
  DropLayerFromWorkspace(lLyr)

  // Delete R output if it exists
  rCSV = outputDir + "/HourlyCapacities.csv"
  rDCC = Substitute(rCSV, ".csv", ".DCC",)
  if GetFileInfo(rCSV) <> null then DeleteFile(rCSV)
  if GetFileInfo(rDCC) <> null then DeleteFile(rDCC)

  // Prepare arguments for "Run R Script"
  hwyBIN = Substitute(hwyDBD, ".dbd", ".bin", )
  OtherArgs = {hwyBIN, outputDir}
  RunMacro("Run R Script", RScriptExe, RScript, OtherArgs)

  // Merge R output back into TransCAD
  // remove this when tcadr can write directly
  {nLyr,lLyr} = GetDBLayers(hwyDBD)
  lLyr = AddLayerToWorkspace(lLyr,hwyDBD,lLyr)

  csv = OpenTable("capacityTable","CSV",{rCSV})
  jv = JoinViews("jv",lLyr + ".ID",csv + ".ID",)
  v_abCapD = GetDataVector(jv + "|",csv + ".ABHourlyCapD",)
  v_baCapD = GetDataVector(jv + "|",csv + ".BAHourlyCapD",)
  v_abCapE = GetDataVector(jv + "|",csv + ".ABHourlyCapE",)
  v_baCapE = GetDataVector(jv + "|",csv + ".BAHourlyCapE",)

  SetDataVector(jv + "|",lLyr + ".ABHourlyCapD",v_abCapD,)
  SetDataVector(jv + "|",lLyr + ".BAHourlyCapD",v_baCapD,)
  SetDataVector(jv + "|",lLyr + ".ABHourlyCapE",v_abCapE,)
  SetDataVector(jv + "|",lLyr + ".BAHourlyCapE",v_baCapE,)

  CloseView(jv)



  // ****** Check results ******
  // Links must have non-zero capacity in the direction of travel
  // or assignment crashes

  v_abCap = GetDataVector(lLyr + "|","ABHourlyCapE",)
  v_baCap = GetDataVector(lLyr + "|","BAHourlyCapE",)
  v_dir = GetDataVector(lLyr + "|","Dir",)
  v_id = GetDataVector(lLyr + "|","ID",)

  v_test1 = if (v_dir = 1 and nz(v_abCap) = 0) then v_id else 0
  v_test2 = if (v_dir = -1 and nz(v_baCap) = 0) then v_id else 0
  v_test3 = if (v_dir = 0 and (nz(v_abCap) = 0 or nz(v_baCap) = 0)) then v_id else 0
  v_test = v_test1 + v_test2 + v_test3

  if VectorStatistic(v_test,"Sum",) > 0 then do
      file = ModelArgs.scenDir + "/outputs/Highway Links with Errors.csv"
      file = OpenFile(file,"w")
      WriteLine(file,"The following links have zero capacity in a direction they shouldn't")
      for i = 1 to v_test.length do
          if v_test[i] <> 0 then WriteLine(file,String(v_test[i]))
      end
      DropLayerFromWorkspace(lLyr)
      Throw("See 'Highway Links with Errors.csv' in the scenario Output folder")
  end

EndMacro

/*
This macro assigns ramp facility types to the highest FT they connect to.

Input:
hwyDBD      String  Full path of the highway geodatabase
rampQuery   String  Query defining which links are ramps
                    e.g. "Select * where Ramp = 1"
ftField     String  Name of the facility type field to use
                    e.g. "HCMType"
a_ftOrder   Array   Order of FT from highest to lowest
                    e.g. {"Freeway", "PrArterial", "Local"}

Output:
Changes the ftField of the ramp links to the FT to use for capacity calculation.
*/

Macro "Assign FT to Ramps" (hwyDBD, rampQuery, ftField, a_ftOrder)

  {nLyr, lLyr} = GetDBLayers(hwyDBD)
  lLyr = AddLayerToWorkspace(lLyr, hwyDBD, lLyr)
  nLyr = AddLayerToWorkspace(nLyr, hwyDBD, nLyr)
  SetLayer(lLyr)
  n1 = SelectByQuery("ramps", "Several", rampQuery)

  if n1 = 0 then do
    Throw("No ramp links found.")
  end else do
    v_rampIDs = GetDataVector(lLyr + "|ramps", "ID", )

    for r = 1 to v_rampIDs.length do
      rampID = v_rampIDs[r]

      minPos = 999
      SetLayer(lLyr)
      a_rampNodeIDs = GetEndPoints(rampID)
      for n = 1 to a_rampNodeIDs.length do
        rampNodeID = a_rampNodeIDs[n]

        SetLayer(nLyr)
        a_linkIDs = GetNodeLinks(rampNodeID)
        for l = 1 to a_linkIDs.length do
          id = a_linkIDs[l]

          SetLayer(lLyr)
          opts = null
          opts.Exact = "True"
          rh = LocateRecord(lLyr + "|", "ID", {id}, opts)
          ft = lLyr.(ftField)
          pos = ArrayPosition(a_ftOrder, {ft}, )
          if pos = 0 then pos = 999
          minPos = min(minPos, pos)
        end
      end

      // If a ramp is only connected to other ramps, code as highest FT
      if minPos = 999 then a_ft = a_ft + {a_ftOrder[1]}
      else a_ft = a_ft + {a_ftOrder[R2I(minPos)]}
    end
  end

  SetDataVector(lLyr + "|ramps", ftField, A2V(a_ft), )
  DropLayerFromWorkspace(lLyr)
  DropLayerFromWorkspace(nLyr)
EndMacro